#!/usr/bin/env bash
# 90-report — verification summary. With AUDIT_ONLY=1 (make audit) it changes nothing.
# See docs/HARDENING.md §90-report and tickets/009.
#
# Exit contract:
#   0  every mandatory control is in the expected state
#   1  at least one mandatory control is not
# Informational lines ([note]/[skip]) never decide the exit code, so the report can stay
# chatty without the gate becoming meaningless.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root

AUDIT_ONLY="${AUDIT_ONLY:-0}"
ADMIN_USER="${ADMIN_USER:-admin}"
TIER="${TIER:-base}"
# 0 = report the Lynis index without judging it. Set e.g. LYNIS_MIN=78 to make a
# regression below the recorded baseline fail the audit.
LYNIS_MIN="${LYNIS_MIN:-0}"

# A dry run applied nothing, so asserting end state would report the pre-existing host
# and fail for the wrong reason. Say so and stop.
if [[ $DRY_RUN == 1 ]]; then
  echo "DRY_RUN=1: nothing was applied — end-state verification skipped"
  exit 0
fi

pass=0
miss=0
skipped=0

check() { # mandatory: a failure fails the audit
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1))
    printf '  [ ok ] %s\n' "$label"
  else
    miss=$((miss + 1))
    printf '  [MISS] %s\n' "$label"
  fi
}

note() { # informational: reported, never fails the audit
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  [ ok ] %s\n' "$label"
  else
    printf '  [note] %s\n' "$label"
  fi
}

skip() { # not verifiable here (unsupported kernel key, WSL, tool absent)
  skipped=$((skipped + 1))
  printf '  [skip] %s\n' "$1"
}

fail() { # a mandatory finding raised outside check()
  miss=$((miss + 1))
  printf '  [MISS] %s\n' "$1"
}

echo "==================== vm-template report ===================="
echo "host: $(hostname)   distro: $os_id $os_codename$(is_wsl && echo '   (WSL)')"

echo "--- state checks ---"
check "password SSH disabled" bash -c "sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'"
check "root SSH disabled" bash -c "sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'"
check "no ecdsa host key offered" bash -c "sshd -T 2>/dev/null | grep -q '^hostkey ' && ! sshd -T 2>/dev/null | grep -q '^hostkey .*ecdsa'"
check "ufw active" bash -c "ufw status 2>/dev/null | grep -qi '^Status: active'"
# fail2ban needs a moment to bring the jail up after a restart earlier in the run.
check "fail2ban sshd jail" bash -c "for _ in 1 2 3 4 5; do fail2ban-client status sshd >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"
check "unattended-upgrades enabled" systemctl is-enabled unattended-upgrades
check "journald persistent" bash -c "grep -qE '^Storage=persistent' /etc/systemd/journald.conf"
check "core dumps disabled" bash -c "grep -qE '^\*\s+hard\s+core\s+0' /etc/security/limits.d/99-vmt-coredump.conf"
# usb-storage is deliberately absent on hosts that boot from USB (65-hardening), so the
# mandatory assertion is the rare-protocol set; usb-storage is reported separately.
check "kernel module blacklist installed" bash -c "grep -qE '^install dccp' /etc/modprobe.d/99-vmt-blacklist.conf"
note "usb-storage blocked" bash -c "grep -qE '^install usb-storage' /etc/modprobe.d/99-vmt-blacklist.conf"
check "login.defs UMASK 027" bash -c "grep -qE '^UMASK[[:space:]]+027' /etc/login.defs"

# The admin must be able to reach root once root SSH login is gone: either a usable
# password with sudo asking for it, or no password at all plus a NOPASSWD drop-in.
admin_priv() {
  id "$ADMIN_USER" >/dev/null 2>&1 || return 1
  id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo || return 1
  local state
  state="$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')"
  [[ $state == P ]] && return 0
  grep -rqs "^$ADMIN_USER .*NOPASSWD" /etc/sudoers.d/
}
check "$ADMIN_USER can escalate to root" admin_priv

note "docker installed" docker --version
if [[ $TIER == full ]]; then
  check "auditd running" bash -c "auditctl -s >/dev/null 2>&1"
else
  note "auditd (TIER=full only)" bash -c "auditctl -s >/dev/null 2>&1"
fi

# --- sysctl -------------------------------------------------------------------
# 60-sysctl applies the file with `sysctl -e`, which ignores keys the running kernel
# does not expose (linux-raspi and other non-generic kernels). That trade only stays
# honest if every key is verified afterwards: a key present in /proc but holding the
# wrong value is a real failure, a key absent from /proc is a documented skip.
sysctl_file=/etc/sysctl.d/99-vmt-hardening.conf

# Exact match, except where the kernel may already sit at a stricter value and refuse to
# move. kernel.unprivileged_bpf_disabled is write-once: Ubuntu ships 2 ("disabled and
# locked"), the file asks for 1, and the write is rejected. 2 is not a regression, so
# that key passes on "at least as strict".
sysctl_value_ok() {
  local key="$1" got="$2" want="$3"
  case "$key" in
    kernel.unprivileged_bpf_disabled)
      [[ $got =~ ^[0-9]+$ && $want =~ ^[0-9]+$ ]] && ((got >= want))
      ;;
    *) [[ $got == "$want" ]] ;;
  esac
}

echo "--- sysctl (from $sysctl_file) ---"
if is_wsl; then
  skip "sysctl sweep (WSL shares the host kernel)"
elif [[ ! -r $sysctl_file ]]; then
  fail "$sysctl_file missing — 60-sysctl has not run"
else
  while read -r key _ want; do
    [[ -n $key && $key != \#* ]] || continue
    if [[ ! -e "/proc/sys/${key//.//}" ]]; then
      skip "$key (not exposed by this kernel)"
      continue
    fi
    got="$(sysctl -n "$key" 2>/dev/null || true)"
    if sysctl_value_ok "$key" "$got" "$want"; then
      pass=$((pass + 1))
      printf '  [ ok ] %s = %s\n' "$key" "$got"
    else
      fail "$key = ${got:-<unreadable>} (want $want)"
    fi
  done < <(grep -E '^[a-z]' "$sysctl_file")
fi

echo "--- ssh-audit ---"
if command -v ssh-audit >/dev/null; then
  audit_out="$(ssh-audit -n -l warn 127.0.0.1 2>/dev/null || true)"
  hits="$(printf '%s\n' "$audit_out" | grep -iE '\[fail\]|\[warn\]' || true)"
  if [[ -n $hits ]]; then
    printf '%s\n' "$hits"
    fail "ssh-audit reported warn/fail findings"
  else
    pass=$((pass + 1))
    echo "  [ ok ] clean (no warn/fail findings)"
  fi
else
  skip "ssh-audit not installed (apt-get install ssh-audit)"
fi

echo "--- Lynis hardening index ---"
if command -v lynis >/dev/null; then
  lynis audit system --quick --quiet >/tmp/vmt-lynis.log 2>&1 || true
  idx="$(awk -F= '/^hardening_index=/{print $2}' /var/log/lynis-report.dat 2>/dev/null | tail -1)"
  warns="$(grep -c '^warning\[\]=' /var/log/lynis-report.dat 2>/dev/null || echo '?')"
  echo "  hardening index: ${idx:-unknown} (target >= 75; fresh images ~50-65)"
  echo "  open warnings:   ${warns:-0} (address warnings before chasing the score)"
  # surface what Lynis actually flagged, so the report is actionable
  if [[ -r /var/log/lynis-report.dat ]]; then
    awk -F'[|=]' '/^warning\[\]=/{print "    warn: "$2" — "$3}' /var/log/lynis-report.dat 2>/dev/null | head -10
    [[ "${LYNIS_SUGGESTIONS:-0}" == 1 ]] &&
      awk -F'[|=]' '/^suggestion\[\]=/{print "    sug:  "$2" — "$3}' /var/log/lynis-report.dat 2>/dev/null | head -30
  fi
  if [[ $LYNIS_MIN != 0 ]]; then
    if [[ ${idx:-} =~ ^[0-9]+$ ]] && ((idx >= LYNIS_MIN)); then
      pass=$((pass + 1))
      echo "  [ ok ] index $idx >= LYNIS_MIN=$LYNIS_MIN"
    else
      fail "Lynis index ${idx:-unknown} below LYNIS_MIN=$LYNIS_MIN"
    fi
  fi
else
  skip "lynis not installed (apt-get install lynis)"
fi

# Per-module CHANGED/OK lines are printed by each module as it runs; this report
# only summarizes end-state, so it does not re-total them (separate processes).
if [[ -f /var/run/reboot-required ]]; then
  echo "NOTE: reboot required (pending kernel/libc update)"
fi

echo "------------------------------------------------------------"
mode="post-harden report"
[[ $AUDIT_ONLY == 1 ]] && mode="audit"
printf 'mode: %s   mandatory: %d passed, %d failed, %d skipped\n' \
  "$mode" "$pass" "$miss" "$skipped"
if ((miss > 0)); then
  echo "RESULT: FAIL — $miss mandatory control(s) not in the expected state"
  echo "============================================================"
  exit 1
fi
echo "RESULT: PASS"
echo "============================================================"
