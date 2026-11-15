#!/usr/bin/env bash
# 65-hardening — login.defs, core-dump limits, kernel-module blacklist.
# The CIS-Level-1 odds and ends that Lynis flags (AUTH-9230/9286/9328,
# KRNL-5820, NETW-3200, USB-1000). See docs/HARDENING.md §65-hardening.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali
skip_if_requested hardening

# Blocking usb-storage is fine on a headless cloud VM and wrong on a board that boots
# from a USB disk — the modprobe.d rule is copied into the initramfs, so the next boot
# would not find its root filesystem. Detected below; the knob forces either answer.
BLOCK_USB_STORAGE="${BLOCK_USB_STORAGE:-auto}"

# --- login.defs: umask, password aging, hashing rounds ----------------------
set_login_def() { # key value
  local key="$1" val="$2" f=/etc/login.defs
  [[ -f $f ]] || return 0
  if grep -qE "^${key}\b" "$f"; then
    local cur
    # `| head -1` would close the pipe early and SIGPIPE awk, which pipefail turns into
    # a failed assignment and set -e turns into an aborted run. Let awk pick the first.
    cur="$(grep -E "^${key}\b" "$f" | awk 'NR==1{print $2}')"
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

# True when the root filesystem sits on a USB device. /sys/block/<disk> resolves
# through the bus controller, so a USB-attached disk has /usbN/ in its device path.
root_on_usb() {
  local src disk
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -n $src ]] || return 1
  disk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)"
  [[ -n $disk ]] || disk="$(lsblk -no KNAME "$src" 2>/dev/null | head -1 || true)"
  [[ -n $disk && -e /sys/block/$disk ]] || return 1
  readlink -f "/sys/block/$disk" | grep -q '/usb[0-9]'
}

case "$BLOCK_USB_STORAGE" in
  auto)
    if root_on_usb; then
      log_warn "root filesystem is on a USB device — not blocking usb-storage (that would make this host unbootable). Set BLOCK_USB_STORAGE=1 to override."
      block_usb=0
    else
      block_usb=1
    fi
    ;;
  1) block_usb=1 ;;
  0) block_usb=0 ;;
  *) die "BLOCK_USB_STORAGE must be auto, 1 or 0 (got '$BLOCK_USB_STORAGE')" ;;
esac

blacklist="# Managed by vm-template (65-hardening).
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true"
if [[ $block_usb == 1 ]]; then
  blacklist+="
install usb-storage /bin/true"
fi
printf '%s\n' "$blacklist" | install_file /etc/modprobe.d/99-vmt-blacklist.conf -

log_ok "os hardening applied (login.defs, core dumps, module blacklist; usb-storage blocked: $block_usb)"
