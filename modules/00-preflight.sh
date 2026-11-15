#!/usr/bin/env bash
# 00-preflight — environment assertions + SSH lockout guard.
# Every other module assumes this passed. See docs/HARDENING.md.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_distro ubuntu debian kali

# --- optional knobs: reject a bad value now, before any module has changed anything ---
validate_skip_modules
validate_flag01 UPDATE_SKIP_DIST_UPGRADE "${UPDATE_SKIP_DIST_UPGRADE:-0}"
glob_to_regex "${UPGRADE_HOLD_PACKAGES:-}" >/dev/null
validate_journal
validate_address_list FAIL2BAN_IGNOREIP "${FAIL2BAN_IGNOREIP:-}"
validate_address_list SSH_ALLOW_FROM "${SSH_ALLOW_FROM:-}"
if [[ -n $SKIP_MODULES ]]; then
  log_ok "SKIP_MODULES=$SKIP_MODULES (those modules do not run and are reported as skipped)"
fi

command -v apt-get >/dev/null || die "apt-get not found"
[[ -d /run/systemd/system ]] || die "systemd is not running (container without systemd?)"
log_ok "distro: $os_id ($os_codename), systemd up, apt available"

# --- SSH lockout guard -------------------------------------------------------
# 30-ssh will disable password + root login. Refuse to arm that unless we can
# prove key-based access exists for someone. Two acceptable proofs:
#   a) an authorized_keys with at least one key for ADMIN_USER or root
#   b) FORCE_LOCKOUT_OK=1 (operator takes responsibility)
ADMIN_USER="${ADMIN_USER:-admin}"
guard_file=/run/vm-template.lockout-ok

has_keys() {
  local f="$1"
  [[ -s $f ]] && grep -qE '^(ssh-(ed25519|rsa)|ecdsa-|sk-)' "$f"
}

if [[ "${FORCE_LOCKOUT_OK:-0}" == 1 ]]; then
  log_warn "lockout guard overridden by FORCE_LOCKOUT_OK=1"
  touch "$guard_file"
elif has_keys "/home/$ADMIN_USER/.ssh/authorized_keys" 2>/dev/null ||
  has_keys /root/.ssh/authorized_keys 2>/dev/null; then
  log_ok "lockout guard: key-based access verified"
  touch "$guard_file"
else
  rm -f "$guard_file"
  log_warn "no authorized_keys found — 30-ssh will REFUSE to disable password auth"
  log_warn "add your public key first (ssh-copy-id), or set FORCE_LOCKOUT_OK=1"
fi
