#!/usr/bin/env bash
# Tier-3 acceptance: create a throwaway Hetzner VM, run the baseline, prove
# idempotence, audit, run the lockout drill, then destroy the VM — even on
# failure (EXIT trap). See docs/TESTING.md.
#
# Env:
#   HCLOUD_TOKEN       Hetzner API token (or an active `hcloud context`)
#   HCLOUD_SSH_KEY     project ssh-key this script connects with. Its private half must
#                      be usable without a prompt (no passphrase, or loaded in an agent).
#   HCLOUD_EXTRA_KEYS  additional project ssh-key names to install on the server, so an
#                      operator can log in with their usual key while the run drives it
#                      with the automation key. Space separated.
#   SSH_KEY_FILE       private key matching HCLOUD_SSH_KEY (default ~/.ssh/id_ed25519)
#   VMT_REPO           local checkout dir (copied via git archive) or a git URL
#   HCLOUD_TYPE        server type (default cpx11; cax11 for arm64)
#   HCLOUD_LOCATION    default ash (cpx11 lives in ash/hil; cax11 in fsn1/nbg1/hel1)
# Usage:  scripts/test-hetzner.sh [ubuntu-24.04|debian-13]
set -euo pipefail

IMAGE="${1:-ubuntu-24.04}"
TYPE="${HCLOUD_TYPE:-cpx11}"
LOCATION="${HCLOUD_LOCATION:-ash}"
NAME="vmt-test-$$"
SSH_KEY="${HCLOUD_SSH_KEY:?set HCLOUD_SSH_KEY to the name from 'hcloud ssh-key list'}"
EXTRA_KEYS="${HCLOUD_EXTRA_KEYS:-}"
KEYFILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519}"
REPO="${VMT_REPO:-.}"

# Delete on every exit path, then confirm it is gone — a leaked server bills by the hour.
cleanup() {
  echo "--- destroying $NAME ---"
  hcloud server delete "$NAME" >/dev/null 2>&1 || true
  if hcloud server describe "$NAME" >/dev/null 2>&1; then
    echo "WARNING: $NAME still exists — delete it by hand" >&2
  else
    echo "  deleted: ok"
  fi
}
trap cleanup EXIT

sshopt=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i "$KEYFILE")
# commands are built locally and run remotely — client-side expansion is intended.
# shellcheck disable=SC2029
ssh_root() { ssh "${sshopt[@]}" "root@$ip" "$@"; }
# shellcheck disable=SC2029
ssh_admin() { ssh "${sshopt[@]}" "admin@$ip" "$@"; }

key_args=(--ssh-key "$SSH_KEY")
for k in $EXTRA_KEYS; do key_args+=(--ssh-key "$k"); done

echo "--- creating $NAME ($TYPE, $IMAGE, keys: $SSH_KEY $EXTRA_KEYS) ---"
hcloud server create --name "$NAME" --type "$TYPE" --image "$IMAGE" \
  --location "$LOCATION" "${key_args[@]}" >/dev/null
ip="$(hcloud server ip "$NAME")"
echo "ip: $ip"

echo "--- waiting for sshd ---"
for _ in $(seq 1 40); do
  ssh_root true 2>/dev/null && break
  sleep 5
done
ssh_root true 2>/dev/null || {
  echo "FAIL: no ssh"
  exit 1
}

echo "--- copying repo + installing make ---"
if [[ -d $REPO ]]; then
  git -C "$REPO" archive HEAD | ssh_root "mkdir -p /opt/vm-template && tar -x -C /opt/vm-template"
else
  ssh_root "DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y git >/dev/null && git clone '$REPO' /opt/vm-template"
fi
# make drives the baseline; lynis + ssh-audit let `make audit` produce a real
# hardening index (they are audit tools, so they belong in the test harness, not
# the hardening modules that run on production).
ssh_root "DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y make lynis ssh-audit >/dev/null"

# NOPASSWD so the admin can re-run harden/audit non-interactively after root SSH
# is disabled. This also exercises the SUDO_NOPASSWD code path.
HARDEN="make harden ADMIN_USER=admin SUDO_NOPASSWD=1 FORCE_LOCKOUT_OK=1 LYNIS_SUGGESTIONS=${LYNIS_SUGGESTIONS:-0}"

echo "--- harden (run 1, as root) ---"
ssh_root "cd /opt/vm-template && $HARDEN"

echo "--- idempotence (run 2, as admin — root SSH is now disabled) ---"
if ssh_admin "cd /opt/vm-template && sudo -n $HARDEN" | grep -q '^CHANGED:'; then
  echo "FAIL: second run reported CHANGES (not idempotent)"
  exit 1
fi
echo "  idempotent: ok"

echo "--- audit ---"
ssh_admin "cd /opt/vm-template && sudo -n make audit"

echo "--- lockout drill ---"
if ssh_root true 2>/dev/null; then
  echo "FAIL: root SSH still allowed"
  exit 1
fi
echo "  root SSH refused: ok"
ssh_admin "sudo -n true && echo admin-sudo-ok" | grep -q admin-sudo-ok && echo "  admin SSH + sudo: ok"
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o ConnectTimeout=10 "admin@$ip" true 2>/dev/null; then
  echo "FAIL: password auth accepted"
  exit 1
fi
echo "  password auth refused: ok"

echo "=== tier-3 acceptance PASSED on $IMAGE ==="
