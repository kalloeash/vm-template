#!/usr/bin/env bash
# Ticket 013 — cloud-init first-boot delivery, verified end to end.
#
# Creates a Hetzner VM whose user-data hardens it before anyone logs in, waits for
# cloud-init to finish, and then checks the box from outside: audit passes, root SSH is
# refused, the admin can still reach root. Deletes the server on every exit path.
#
# The repo is delivered as a base64 payload in user-data rather than a git clone, so the
# test needs no credentials and no network access to a private remote. The shipped
# example in examples/cloud-init.yaml uses the clone, which is the right pattern for a
# public repo; what is under test here is the first-boot execution, not the transport.
#
# Env: HCLOUD_TOKEN, HCLOUD_SSH_KEY, SSH_KEY_FILE, HCLOUD_EXTRA_KEYS, HCLOUD_TYPE,
#      HCLOUD_LOCATION — same meanings as scripts/test-hetzner.sh.
# Usage: scripts/test-cloud-init.sh [ubuntu-24.04|debian-13]
set -euo pipefail

IMAGE="${1:-ubuntu-24.04}"
TYPE="${HCLOUD_TYPE:-cpx11}"
LOCATION="${HCLOUD_LOCATION:-ash}"
NAME="vmt-ci-$$"
SSH_KEY="${HCLOUD_SSH_KEY:?set HCLOUD_SSH_KEY}"
EXTRA_KEYS="${HCLOUD_EXTRA_KEYS:-}"
KEYFILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519}"
REPO="${VMT_REPO:-.}"

workdir="$(mktemp -d)"
cleanup() {
  echo "--- destroying $NAME ---"
  hcloud server delete "$NAME" >/dev/null 2>&1 || true
  if hcloud server describe "$NAME" >/dev/null 2>&1; then
    echo "WARNING: $NAME still exists — delete it by hand" >&2
  else
    echo "  deleted: ok"
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

sshopt=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i "$KEYFILE")
# shellcheck disable=SC2029
ssh_admin() { ssh "${sshopt[@]}" "admin@$ip" "$@"; }
# shellcheck disable=SC2029
ssh_root() { ssh "${sshopt[@]}" "root@$ip" "$@"; }
run_admin() { ssh_admin "$@" 2>&1 || true; }

pubkey="$(ssh-keygen -y -f "$KEYFILE")"

echo "--- building user-data ---"
# Only what the baseline needs to run; the full tree does not fit in 32KB of user-data.
git -C "$REPO" archive HEAD modules lib Makefile | gzip -9 >"$workdir/vmt.tgz"
payload="$(base64 -w0 <"$workdir/vmt.tgz")"

cat >"$workdir/user-data.yaml" <<EOF
#cloud-config
package_update: true
packages: [make]

users:
  - name: admin
    groups: [sudo]
    shell: /bin/bash
    # NOPASSWD, because cloud-init creates this account with no password. Pairing a
    # locked password with a sudo password prompt leaves no path to root at all.
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - $pubkey

ssh_pwauth: false

write_files:
  - path: /opt/vmt.tgz
    encoding: b64
    permissions: '0600'
    content: $payload

runcmd:
  - [mkdir, -p, /opt/vm-template]
  - [tar, -xzf, /opt/vmt.tgz, -C, /opt/vm-template]
  # FORCE_LOCKOUT_OK is safe here: cloud-init injected the admin key above.
  - [bash, -lc, "cd /opt/vm-template && make harden ADMIN_USER=admin FORCE_LOCKOUT_OK=1 >/var/log/vmt-harden.log 2>&1"]
EOF

size="$(wc -c <"$workdir/user-data.yaml")"
echo "  user-data: $size bytes"
if ((size > 32768)); then
  echo "FAIL: user-data exceeds the 32KB limit"
  exit 1
fi

key_args=(--ssh-key "$SSH_KEY")
for k in $EXTRA_KEYS; do key_args+=(--ssh-key "$k"); done

echo "--- creating $NAME ($TYPE, $IMAGE) with first-boot hardening ---"
hcloud server create --name "$NAME" --type "$TYPE" --image "$IMAGE" \
  --location "$LOCATION" "${key_args[@]}" --user-data-from-file "$workdir/user-data.yaml" >/dev/null
ip="$(hcloud server ip "$NAME")"
echo "ip: $ip"

# Connect as admin, never as root: if the delivery works, root login is already gone by
# the time the box is reachable. That is the whole point of path B.
echo "--- waiting for the admin account (cloud-init is still running) ---"
for _ in $(seq 1 60); do
  ssh_admin true 2>/dev/null && break
  sleep 5
done
ssh_admin true 2>/dev/null || {
  echo "FAIL: admin never became reachable"
  exit 1
}

echo "--- waiting for cloud-init to finish ---"
status="$(run_admin "sudo -n cloud-init status --wait")"
echo "  $status"
if ! grep -q 'status: done' <<<"$status"; then
  echo "FAIL: cloud-init did not finish cleanly"
  run_admin "sudo -n tail -40 /var/log/vmt-harden.log"
  exit 1
fi

echo "--- did the baseline actually run at first boot? ---"
harden_tail="$(run_admin "sudo -n tail -5 /var/log/vmt-harden.log")"
if ! grep -q 'RESULT: PASS' <<<"$harden_tail"; then
  echo "FAIL: harden did not report PASS at first boot"
  run_admin "sudo -n tail -40 /var/log/vmt-harden.log"
  exit 1
fi
echo "  harden completed at first boot: ok"

echo "--- the box is hardened before anyone logged in ---"
audit="$(run_admin "cd /opt/vm-template && sudo -n make audit")"
if ! grep -q 'RESULT: PASS' <<<"$audit"; then
  echo "FAIL: audit did not pass"
  printf '%s\n' "$audit" | tail -30
  exit 1
fi
echo "  make audit: pass"

# Positive check first. The root-login check below fails authentication on purpose,
# which is what fail2ban bans for, and a banned client cannot open a new connection.
if ! grep -q admin-sudo-ok <<<"$(run_admin "sudo -n true && echo admin-sudo-ok")"; then
  echo "FAIL: admin cannot reach root"
  exit 1
fi
echo "  admin SSH + sudo: ok"

if ssh_root true 2>/dev/null; then
  echo "FAIL: root SSH still allowed after first-boot hardening"
  exit 1
fi
echo "  root SSH refused: ok"

echo "=== cloud-init delivery PASSED on $IMAGE ==="
