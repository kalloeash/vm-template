#!/usr/bin/env bash
# 65-hardening — login.defs, core-dump limits, kernel-module blacklist.
# The CIS-Level-1 odds and ends that Lynis flags (AUTH-9230/9286/9328,
# KRNL-5820, NETW-3200, USB-1000). See docs/HARDENING.md §65-hardening.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

# --- login.defs: umask, password aging, hashing rounds ----------------------
set_login_def() { # key value
  local key="$1" val="$2" f=/etc/login.defs
  [[ -f $f ]] || return 0
  if grep -qE "^${key}\b" "$f"; then
    local cur
    cur="$(grep -E "^${key}\b" "$f" | awk '{print $2}' | head -1)"
    if [[ $cur == "$val" ]]; then
      log_ok "login.defs $key=$val"
    elif [[ $DRY_RUN == 1 ]]; then
      log_changed "login.defs $key -> $val (dry-run)"
    else
      sed -i -E "s|^${key}\b.*|${key}\t${val}|" "$f"
      log_changed "login.defs $key -> $val"
    fi
  elif [[ $DRY_RUN == 1 ]]; then
    log_changed "login.defs add $key $val (dry-run)"
  else
    printf '%s\t%s\n' "$key" "$val" >>"$f"
    log_changed "login.defs add $key $val"
  fi
}
set_login_def UMASK 027
set_login_def PASS_MAX_DAYS 365
set_login_def PASS_MIN_DAYS 1
set_login_def PASS_WARN_AGE 7
set_login_def SHA_CRYPT_MIN_ROUNDS 640000

# --- disable core dumps (KRNL-5820; pairs with fs.suid_dumpable in 60) -------
install_file /etc/security/limits.d/99-vmt-coredump.conf - <<'EOF'
# Managed by vm-template (65-hardening): no core dumps.
* hard core 0
* soft core 0
EOF

# --- blacklist rarely-used, attack-surface kernel modules --------------------
# Rare network protocols (NETW-3200) and USB storage (USB-1000). Harmless on a
# headless server; "install ... /bin/true" makes modprobe refuse to load them.
install_file /etc/modprobe.d/99-vmt-blacklist.conf - <<'EOF'
# Managed by vm-template (65-hardening).
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
install usb-storage /bin/true
EOF

log_ok "os hardening applied (login.defs, core dumps, module blacklist)"
