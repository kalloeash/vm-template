#!/usr/bin/env bash
# 20-user — non-root admin with sudo and key-based access.
# See docs/HARDENING.md §20-user and tickets/003.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

ADMIN_USER="${ADMIN_USER:-admin}"
SUDO_NOPASSWD="${SUDO_NOPASSWD:-0}"

# --- create the account (no password; keys only) -----------------------------
if id "$ADMIN_USER" &>/dev/null; then
  log_ok "user $ADMIN_USER exists"
else
  run "create user $ADMIN_USER" useradd -m -s /bin/bash "$ADMIN_USER"
  # lock the password so only key auth works, without disabling the account
  [[ $DRY_RUN == 1 ]] || passwd -l "$ADMIN_USER" >/dev/null
fi

# --- sudo group --------------------------------------------------------------
if id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
  log_ok "$ADMIN_USER already in sudo"
else
  run "add $ADMIN_USER to sudo" usermod -aG sudo "$ADMIN_USER"
fi

if [[ $SUDO_NOPASSWD == 1 ]]; then
  install_file "/etc/sudoers.d/90-vmt-$ADMIN_USER" - 0440 <<EOF
$ADMIN_USER ALL=(ALL) NOPASSWD:ALL
EOF
else
  log_ok "sudo requires password (SUDO_NOPASSWD=0)"
fi

# --- authorized_keys: seed from root if the admin has none -------------------
# getent fails when the user does not exist yet (e.g. dry-run) — fall back to the
# conventional home path rather than aborting under set -e.
admin_home="$(getent passwd "$ADMIN_USER" 2>/dev/null | cut -d: -f6 || true)"
[[ -n $admin_home ]] || admin_home="/home/$ADMIN_USER"
admin_ssh="$admin_home/.ssh"
admin_keys="$admin_ssh/authorized_keys"
root_keys="/root/.ssh/authorized_keys"

has_key() { [[ -s $1 ]] && grep -qE '^(ssh-(ed25519|rsa)|ecdsa-|sk-)' "$1"; }

if has_key "$admin_keys"; then
  log_ok "$ADMIN_USER already has authorized_keys"
elif has_key "$root_keys"; then
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "would copy root authorized_keys to $admin_keys (dry-run)"
  else
    install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$admin_ssh"
    install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$root_keys" "$admin_keys"
    log_changed "copied root authorized_keys to $admin_keys"
  fi
else
  log_warn "no authorized_keys for $ADMIN_USER or root — add one before 30-ssh disables passwords"
fi
