#!/usr/bin/env bash
# 20-user — non-root admin with sudo and key-based access.
# See docs/HARDENING.md §20-user and tickets/003.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali
skip_if_requested user

ADMIN_USER="${ADMIN_USER:-admin}"
# crypt(3) hash, e.g. `openssl passwd -6` or `mkpasswd -m sha512crypt`.
# Empty (the default) means a key-only account with no password at all.
#
# Pass this through the ENVIRONMENT, not as a make variable: make expands `$` in
# command-line variables, so `make user ADMIN_PASSWORD_HASH='$6$salt$...'` arrives here
# mangled. `sudo ADMIN_PASSWORD_HASH='...' make user` works. ADMIN_PASSWORD_HASH_FILE
# avoids the question entirely and keeps the hash out of the process list.
ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH:-}"
ADMIN_PASSWORD_HASH_FILE="${ADMIN_PASSWORD_HASH_FILE:-}"
if [[ -n $ADMIN_PASSWORD_HASH_FILE ]]; then
  [[ -r $ADMIN_PASSWORD_HASH_FILE ]] || die "ADMIN_PASSWORD_HASH_FILE is not readable: $ADMIN_PASSWORD_HASH_FILE"
  ADMIN_PASSWORD_HASH="$(head -n1 "$ADMIN_PASSWORD_HASH_FILE" | tr -d '\r\n')"
fi

# What to do about the admin's sudo rights; see validate_admin_sudo in lib/common.sh.
# keep leaves the sudo group and all sudoers rules as found, for an appliance image that
# ships a narrow rule for the admin on purpose.
ADMIN_SUDO="${ADMIN_SUDO:-}"
validate_admin_sudo

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
    die "ADMIN_PASSWORD_HASH is not a crypt(3) hash: '${ADMIN_PASSWORD_HASH:0:12}...'
         Generate one with: openssl passwd -6
         If you passed it as a make variable, that is the problem — make expands \$ in
         command-line variables. Use the environment instead:
           sudo ADMIN_PASSWORD_HASH=\"\$(openssl passwd -6)\" make user ADMIN_USER=$ADMIN_USER
         or point ADMIN_PASSWORD_HASH_FILE at a file containing the hash."
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
if [[ $ADMIN_SUDO == keep ]]; then
  # Nothing is added or widened. Only check that some sudo rule exists for the account,
  # so root SSH login being off does not strand the admin; the audit reports the rest as
  # informational (it cannot judge a custom rule).
  if [[ $DRY_RUN == 1 ]]; then
    log_ok "ADMIN_SUDO=keep: sudo group and sudoers rules for $ADMIN_USER left as found (dry-run, not checked)"
  elif ! id "$ADMIN_USER" &>/dev/null; then
    log_warn "ADMIN_SUDO=keep but $ADMIN_USER does not exist"
  elif sudo -n -l -U "$ADMIN_USER" 2>/dev/null | grep -qE '^[[:space:]]+\('; then
    log_ok "ADMIN_SUDO=keep: $ADMIN_USER has a sudo rule; groups and sudoers left as found"
  else
    log_warn "ADMIN_SUDO=keep but 'sudo -l -U $ADMIN_USER' lists no rule — the admin may have no way to root"
  fi
elif id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
  log_ok "$ADMIN_USER already in sudo"
else
  run "add $ADMIN_USER to sudo" usermod -aG sudo "$ADMIN_USER"
fi

# --- sudo password policy ----------------------------------------------------
if [[ $ADMIN_SUDO == nopasswd ]]; then
  SUDO_NOPASSWD=1
elif [[ $ADMIN_SUDO == password ]]; then
  SUDO_NOPASSWD=0
elif [[ $has_password == 1 ]]; then
  SUDO_NOPASSWD="${SUDO_NOPASSWD:-0}"
else
  SUDO_NOPASSWD="${SUDO_NOPASSWD:-1}"
fi

if [[ $ADMIN_SUDO != keep && $SUDO_NOPASSWD != 1 && $has_password != 1 ]]; then
  die "$ADMIN_USER has no usable password but SUDO_NOPASSWD=0 — sudo would be unusable
         once 30-ssh disables root login. Set ADMIN_PASSWORD_HASH=<crypt hash> for a
         password-based model, or SUDO_NOPASSWD=1 for the key-only model."
fi

sudoers="/etc/sudoers.d/90-vmt-$ADMIN_USER"
if [[ $ADMIN_SUDO == keep ]]; then
  log_ok "sudoers left as found (ADMIN_SUDO=keep)"
elif [[ $SUDO_NOPASSWD == 1 ]]; then
  install_file "$sudoers" - 0440 <<EOF
$ADMIN_USER ALL=(ALL) NOPASSWD:ALL
EOF
  if [[ $DRY_RUN != 1 ]] && ! visudo -cf "$sudoers" >/dev/null 2>&1; then
    rm -f "$sudoers"
    die "generated $sudoers failed visudo -c — removed it rather than leaving it in place"
  fi
  if [[ $has_password == 1 ]]; then
    log_ok "sudo without password for $ADMIN_USER (SUDO_NOPASSWD=1, overriding the password model)"
  else
    log_ok "sudo without password for $ADMIN_USER (key-only account, nothing to type)"
  fi
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
