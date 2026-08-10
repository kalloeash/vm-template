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

# Never pipe an ssh command straight into `grep -q`. grep exits on the first match, ssh
# takes SIGPIPE, and `set -o pipefail` makes the pipeline non-zero *because* the pattern
# matched — so `if cmd | grep -q X` is false whether X is there or not. Capture first.
run_admin() { ssh_admin "$@" 2>&1 || true; }

echo "--- idempotence (run 2, as admin — root SSH is now disabled) ---"
run2="$(run_admin "cd /opt/vm-template && sudo -n $HARDEN")"
if grep -q '^CHANGED:' <<<"$run2"; then
  echo "FAIL: second run reported CHANGES (not idempotent):"
  grep '^CHANGED:' <<<"$run2"
  exit 1
fi
echo "  idempotent: ok"

echo "--- audit ---"
ssh_admin "cd /opt/vm-template && sudo -n make audit"

# EXTENDED=1 adds the acceptance criteria that need a real host and a deliberate break:
# the audit gate, the sshd rollback, the two privilege models, TIER=full. They run before
# the lockout drill because that drill ends with this client banned.
if [[ ${EXTENDED:-0} == 1 ]]; then
  echo "--- extended drills ---"

  # tickets/005 — EXTRA_PORTS defaults to empty, so only SSH should be open
  if ssh_admin "sudo -n ufw status | grep -qE '^(80|443)/tcp'"; then
    echo "FAIL: 80/443 are open without EXTRA_PORTS being asked for"
    exit 1
  fi
  echo "  firewall opens SSH only: ok"

  # tickets/003 — the password model: a hash means a real password and no NOPASSWD file.
  # The hash goes through the environment: make expands $ in command-line variables.
  ssh_admin "cd /opt/vm-template && sudo -n env \
    ADMIN_PASSWORD_HASH=\"\$(openssl passwd -6 -salt vmtsalt vmt-test-pw)\" \
    make user ADMIN_USER=ops" >/dev/null

  # ...and the make-variable form must fail loudly rather than half-work
  if ssh_admin "cd /opt/vm-template && sudo -n make user ADMIN_USER=ops3 \
    ADMIN_PASSWORD_HASH='\$6\$vmtsalt\$notarealhash'" >/dev/null 2>&1; then
    echo "FAIL: a make-mangled ADMIN_PASSWORD_HASH was accepted"
    exit 1
  fi
  echo "  make-variable password hash rejected with an explanation: ok"
  if ssh_admin "sudo -n test -f /etc/sudoers.d/90-vmt-ops"; then
    echo "FAIL: a password-model account was given a NOPASSWD drop-in"
    exit 1
  fi
  if ! grep -qx P <<<"$(run_admin "sudo -n passwd -S ops | awk '{print \$2}'")"; then
    echo "FAIL: ADMIN_PASSWORD_HASH did not produce a usable password"
    exit 1
  fi
  echo "  password model (ADMIN_PASSWORD_HASH): ok"

  # tickets/003 — the combination that used to ship a host with no path to root
  if ssh_admin "cd /opt/vm-template && sudo -n make user ADMIN_USER=ops2 SUDO_NOPASSWD=0" >/dev/null 2>&1; then
    echo "FAIL: SUDO_NOPASSWD=0 on a password-less account was accepted"
    exit 1
  fi
  echo "  password-less account with SUDO_NOPASSWD=0 refused: ok"

  # tickets/004 criterion 6 — a drop-in sshd rejects must not survive on disk.
  # A second drop-in makes the *effective* config invalid, so the module's own file is
  # written and then has to be rolled back.
  ssh_admin "sudo -n bash -c 'echo NotADirective yes > /etc/ssh/sshd_config.d/99-vmt-bogus.conf; rm -f /etc/ssh/sshd_config.d/10-hardening.conf'"
  if ssh_admin "cd /opt/vm-template && sudo -n make ssh" >/dev/null 2>&1; then
    echo "FAIL: make ssh succeeded against a config sshd rejects"
    exit 1
  fi
  if ssh_admin "sudo -n test -f /etc/ssh/sshd_config.d/10-hardening.conf"; then
    echo "FAIL: the rejected drop-in was left on disk"
    exit 1
  fi
  echo "  sshd rollback removed the rejected drop-in: ok"
  ssh_admin "sudo -n rm -f /etc/ssh/sshd_config.d/99-vmt-bogus.conf"
  ssh_admin "cd /opt/vm-template && sudo -n make ssh" >/dev/null
  if ! ssh_admin "sudo -n sshd -T | grep -qx 'passwordauthentication no'"; then
    echo "FAIL: the hardened sshd config did not come back"
    exit 1
  fi
  echo "  sshd config restored after the rollback: ok"

  # tickets/009 criterion 5 — make audit has to fail on a broken mandatory control
  ssh_admin "sudo -n ufw disable" >/dev/null
  if ssh_admin "cd /opt/vm-template && sudo -n make audit" >/dev/null 2>&1; then
    echo "FAIL: make audit passed with ufw disabled"
    exit 1
  fi
  echo "  make audit fails on a broken control: ok"
  ssh_admin "sudo -n ufw --force enable" >/dev/null

  # tickets/009 — the optional tier actually loads its rules
  ssh_admin "cd /opt/vm-template && sudo -n make harden TIER=full ADMIN_USER=admin SUDO_NOPASSWD=1 FORCE_LOCKOUT_OK=1" >/dev/null
  if ! ssh_admin "sudo -n auditctl -l | grep -q identity"; then
    echo "FAIL: TIER=full did not load the auditd ruleset"
    exit 1
  fi
  echo "  TIER=full auditd rules loaded: ok"
fi

echo "--- lockout drill ---"
# Order matters. The negative checks deliberately fail authentication, which is exactly
# what fail2ban bans for, and the ban drops this client's packets on port 22 — including
# already-established connections. So every check that needs to reach the host runs
# first, and the ones that expect a refusal run last.

if ! grep -q admin-sudo-ok <<<"$(run_admin "sudo -n true && echo admin-sudo-ok")"; then
  echo "FAIL: admin SSH + sudo does not work — the account cannot reach root"
  exit 1
fi
echo "  admin SSH + sudo: ok"

# Assert the wiring that silently breaks on 24.04 and Debian 13: sshd logs to the
# journal, so a jail left on the default `auto` backend reads nothing and never bans
# while still reporting itself healthy. A journal match proves backend=systemd took.
if grep -q '_SYSTEMD_UNIT' <<<"$(run_admin "sudo -n fail2ban-client get sshd journalmatch")"; then
  echo "  fail2ban sshd jail reads the journal: ok"
else
  echo "FAIL: sshd jail has no journal match — fail2ban is watching nothing"
  exit 1
fi

if ssh_root true 2>/dev/null; then
  echo "FAIL: root SSH still allowed"
  exit 1
fi
echo "  root SSH refused: ok"

if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o ConnectTimeout=10 "admin@$ip" true 2>/dev/null; then
  echo "FAIL: password auth accepted"
  exit 1
fi
echo "  password auth refused: ok"
echo "  (this client is now most likely banned by fail2ban — expected, the drill is over)"

echo "=== tier-3 acceptance PASSED on $IMAGE ==="
