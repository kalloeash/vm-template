#!/usr/bin/env bash
# Tier-3 acceptance: create a throwaway Hetzner VM, run the baseline, audit it,
# run the lockout drill, then destroy the VM — even on failure (trap).
# Prereqs: hcloud CLI in an active context, an uploaded ssh-key, a local private
# key that matches it. See docs/TESTING.md.
#
#   HCLOUD_SSH_KEY=<name-in-hetzner> SSH_KEY_FILE=~/.ssh/id_ed25519 \
#     scripts/test-hetzner.sh [ubuntu-24.04|debian-13]
set -euo pipefail

IMAGE="${1:-ubuntu-24.04}"
TYPE="${HCLOUD_TYPE:-cx22}"
NAME="vmt-test-$$"
SSH_KEY="${HCLOUD_SSH_KEY:?set HCLOUD_SSH_KEY to the ssh-key name shown by 'hcloud ssh-key list'}"
KEYFILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519}"
REPO="${VMT_REPO:-https://github.com/kalloeash/vm-template.git}"

cleanup() { echo "--- destroying $NAME ---"; hcloud server delete "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "--- creating $NAME ($TYPE, $IMAGE) ---"
hcloud server create --name "$NAME" --type "$TYPE" --image "$IMAGE" --ssh-key "$SSH_KEY" >/dev/null
ip="$(hcloud server ip "$NAME")"
echo "ip: $ip"

ssh_root() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEYFILE" "root@$ip" "$@"; }

echo "--- waiting for sshd ---"
for _ in $(seq 1 30); do ssh_root true 2>/dev/null && break; sleep 5; done

echo "--- harden ---"
ssh_root "git clone $REPO /opt/vm-template && cd /opt/vm-template && make harden ADMIN_USER=admin FORCE_LOCKOUT_OK=1"

echo "--- idempotence: second run must be all-OK ---"
if ssh_root "cd /opt/vm-template && make harden ADMIN_USER=admin FORCE_LOCKOUT_OK=1" | grep -q '^CHANGED:'; then
  echo "FAIL: second run reported CHANGES (not idempotent)"; exit 1
fi

echo "--- audit ---"
ssh_root "cd /opt/vm-template && make audit"

echo "--- lockout drill ---"
# root must now be refused; admin key must work; password auth must be refused.
if ssh_root true 2>/dev/null; then echo "FAIL: root SSH still allowed"; exit 1; fi
echo "  root SSH refused: ok"
ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$KEYFILE" "admin@$ip" "sudo -n true 2>/dev/null || sudo true; echo admin-ok" \
  && echo "  admin SSH + sudo: ok"
if ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "admin@$ip" true 2>/dev/null; then
  echo "FAIL: password auth accepted"; exit 1
fi
echo "  password auth refused: ok"

echo "=== tier-3 acceptance PASSED on $IMAGE ==="
