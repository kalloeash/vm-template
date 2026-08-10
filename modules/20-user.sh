#!/usr/bin/env bash
# 20-user — non-root admin with sudo and key-based access.
# See docs/HARDENING.md §20-user and tickets/003.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

ADMIN_USER="${ADMIN_USER:-admin}"
# crypt(3) hash, e.g. `openssl passwd -6` or `mkpasswd -m sha512crypt`.
# Empty (the default) means a key-only account with no password at all.
ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH:-}"

# The name is interpolated into a sudoers file — reject anything that is not a
# plain login name before it gets there.
[[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid ADMIN_USER '$ADMIN_USER'"

# --- create the account ------------------------------------------------------
created=0
if id "$ADMIN_USER" &>/dev/null; then
  log_ok "user $ADMIN_USER exists"
else
  run "create user $ADMIN_USER" useradd -m -s /bin/bash "$ADMIN_USER"
  created=1
fi

# --- password state ----------------------------------------------------------
# Two models, both usable end to end once 30-ssh disables root login:
#   key-only   no password at all      -> sudo must not ask for one
#   password   ADMIN_PASSWORD_HASH set -> sudo asks for that password
# Locking the password while sudo still demands one leaves the admin with no way
# to escalate, so the two settings are derived together below.
pw_state() { passwd -S "$1" 2>/dev/null | awk '{print $2}'; }

if [[ -n $ADMIN_PASSWORD_HASH ]]; then
  [[ $ADMIN_PASSWORD_HASH == \$*\$* ]] ||
    die "ADMIN_PASSWORD_HASH must be a crypt(3) hash (openssl passwd -6), not a plaintext password"
  cur_hash="$(getent shadow "$ADMIN_USER" 2>/dev/null | cut -d: -f2 || true)"
  if [[ $cur_hash == "$ADMIN_PASSWORD_HASH" ]]; then
    log_ok "$ADMIN_USER password hash up to date"
  elif [[ $DRY_RUN == 1 ]]; then
    log_changed "would set $ADMIN_USER password from ADMIN_PASSWORD_HASH (dry-run)"
  else
    printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" | chpasswd -e
    log_changed "set $ADMIN_USER password from ADMIN_PASSWORD_HASH"
  fi
elif [[ $created == 1 ]]; then
  # Freshly created and no hash supplied: lock the password so only keys work.
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "would lock password for $ADMIN_USER (key-only account, dry-run)"
  else
    passwd -l "$ADMIN_USER" >/dev/null
    log_changed "locked password for $ADMIN_USER (key-only account)"
  fi
else
  # Pre-existing account: never take away a password the operator relies on.
  log_ok "$ADMIN_USER password state left as found (passwd -S: $(pw_state "$ADMIN_USER"))"
fi

has_password=0
[[ -n $ADMIN_PASSWORD_HASH ]] && has_password=1
[[ $(pw_state "$ADMIN_USER") == P ]] && has_password=1

# --- sudo group --------------------------------------------------------------
if id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
  log_ok "$ADMIN_USER already in sudo"
else
  run "add $ADMIN_USER to sudo" usermod -aG sudo "$ADMIN_USER"
fi

# --- sudo password policy ----------------------------------------------------
if [[ $has_password == 1 ]]; then
  SUDO_NOPASSWD="${SUDO_NOPASSWD:-0}"
else
  SUDO_NOPASSWD="${SUDO_NOPASSWD:-1}"
fi

if [[ $SUDO_NOPASSWD != 1 && $has_password != 1 ]]; then
  die "$ADMIN_USER has no usable password but SUDO_NOPASSWD=0 — sudo would be unusable
         once 30-ssh disables root login. Set ADMIN_PASSWORD_HASH=<crypt hash> for a
         password-based model, or SUDO_NOPASSWD=1 for the key-only model."
fi

sudoers="/etc/sudoers.d/90-vmt-$ADMIN_USER"
if [[ $SUDO_NOPASSWD == 1 ]]; then
  install_file "$sudoers" - 0440 <<EOF
$ADMIN_USER ALL=(ALL) NOPASSWD:ALL
EOF
  if [[ $DRY_RUN != 1 ]] && ! visudo -cf "$sudoers" >/dev/null 2>&1; then
    rm -f "$sudoers"
    die "generated $sudoers failed visudo -c — removed it rather than leaving it in place"
  fi
  log_ok "sudo without password for $ADMIN_USER (account has no password to type)"
elif [[ -f $sudoers ]]; then
  run "remove NOPASSWD drop-in $sudoers" rm -f "$sudoers"
else
  log_ok "sudo requires $ADMIN_USER's password (SUDO_NOPASSWD=0)"
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
