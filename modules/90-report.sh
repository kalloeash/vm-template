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

# Same knobs the modules read, so the audit judges the host against what was asked for:
# a module in SKIP_MODULES is reported [skip] with the reason, and JOURNAL_STORAGE selects
# which journald state counts as correct. Both are validated here as well, because
# `make audit` does not run preflight.
validate_skip_modules
validate_journal
validate_admin_sudo

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

# check/note/skip for a control that belongs to one module: when the caller skipped that
# module the control was never applied, so it is reported as skipped, not as a failure.
mcheck() { # mcheck MODULE LABEL cmd...
  local mod="$1"
  shift
  if module_skipped "$mod"; then skip "$1 (module $mod skipped: SKIP_MODULES)"; else check "$@"; fi
}
mnote() {
  local mod="$1"
  shift
  if module_skipped "$mod"; then skip "$1 (module $mod skipped: SKIP_MODULES)"; else note "$@"; fi
}

fail() { # a mandatory finding raised outside check()
  miss=$((miss + 1))
  printf '  [MISS] %s\n' "$1"
}

echo "==================== vm-template report ===================="
echo "host: $(hostname)   distro: $os_id $os_codename$(is_wsl && echo '   (WSL)')"

echo "--- state checks ---"
mcheck ssh "password SSH disabled" bash -c "sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'"
mcheck ssh "root SSH disabled" bash -c "sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'"
mcheck ssh "no ecdsa host key offered" bash -c "sshd -T 2>/dev/null | grep -q '^hostkey ' && ! sshd -T 2>/dev/null | grep -q '^hostkey .*ecdsa'"
# Logjam: a 2048-bit group in /etc/ssh/moduli is negotiable regardless of the drop-in.
mcheck ssh "ssh moduli >= ${SSH_MIN_MODULUS:-3071} bits" bash -c \
  "[[ ! -f /etc/ssh/moduli ]] || [[ \$(awk -v m=${SSH_MIN_MODULUS:-3071} '!/^#/ && NF >= 5 && \$5 < m' /etc/ssh/moduli | wc -l) -eq 0 ]]"
mcheck ssh "rsa host key >= 3072 bits" bash -c \
  "[[ ! -f /etc/ssh/ssh_host_rsa_key ]] || [[ \$(ssh-keygen -lf /etc/ssh/ssh_host_rsa_key 2>/dev/null | awk '{print \$1}') -ge 3072 ]]"
mcheck firewall "ufw active" bash -c "ufw status 2>/dev/null | grep -qi '^Status: active'"
# fail2ban needs a moment to bring the jail up after a restart earlier in the run.
mcheck fail2ban "fail2ban sshd jail" bash -c "for _ in 1 2 3 4 5; do fail2ban-client status sshd >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"
mcheck update "unattended-upgrades enabled" systemctl is-enabled unattended-upgrades
# 80-auditd owns journald. Persistent (default): the main file says so. Volatile: the
# drop-in says so and carries the size cap, so the audit accepts exactly what was asked for.
if [[ $JOURNAL_STORAGE == volatile ]]; then
  mcheck auditd "journald volatile, capped at $JOURNAL_VOLATILE_MAX_USE" bash -c \
    "grep -qE '^Storage=volatile' '$VMT_JOURNALD_DROPIN' && grep -qE '^RuntimeMaxUse=$JOURNAL_VOLATILE_MAX_USE\$' '$VMT_JOURNALD_DROPIN'"
else
  mcheck auditd "journald persistent" bash -c "grep -qE '^Storage=persistent' '$VMT_JOURNALD_CONF'"
fi
mcheck hardening "core dumps disabled" bash -c "grep -qE '^\*\s+hard\s+core\s+0' /etc/security/limits.d/99-vmt-coredump.conf"
# usb-storage is deliberately absent on hosts that boot from USB (65-hardening), so the
# mandatory assertion is the rare-protocol set; usb-storage is reported separately.
mcheck hardening "kernel module blacklist installed" bash -c "grep -qE '^install dccp' /etc/modprobe.d/99-vmt-blacklist.conf"
mnote hardening "usb-storage blocked" bash -c "grep -qE '^install usb-storage' /etc/modprobe.d/99-vmt-blacklist.conf"
mcheck hardening "login.defs UMASK 027" bash -c "grep -qE '^UMASK[[:space:]]+027' /etc/login.defs"

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
# ADMIN_SUDO=keep means the sudo rules are the image's own (possibly narrow on purpose),
# so the control is informational: it is reported, never fails the audit.
if [[ ${ADMIN_SUDO:-} == keep ]]; then
  mnote user "$ADMIN_USER can escalate to root (ADMIN_SUDO=keep: rules left as found, informational)" admin_priv
else
  mcheck user "$ADMIN_USER can escalate to root" admin_priv
fi

mnote docker "docker installed" docker --version
if [[ $TIER == full ]]; then
  mcheck auditd "auditd running" bash -c "auditctl -s >/dev/null 2>&1"
else
  mnote auditd "auditd (TIER=full only)" bash -c "auditctl -s >/dev/null 2>&1"
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
if module_skipped sysctl; then
  skip "sysctl sweep (module sysctl skipped: SKIP_MODULES)"
elif is_wsl; then
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
# ssh-audit at -l warn prints nothing for a clean server — and also nothing when it could
# not connect at all. Establish that sshd is actually listening first, or "clean" would
# mean "no ssh daemon", which is not the same thing.
# No early `exit` in the awk: under `set -o pipefail` an awk that stops reading sends
# SIGPIPE to sshd -T, the pipeline returns 141, and the whole report aborts.
# `|| true`: with no sshd on PATH the pipeline fails, and under set -e that would end the
# whole report here instead of reaching the "sshd is not listening" finding below.
sshd_port="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' || true)"
sshd_port="${sshd_port:-22}"
if module_skipped ssh; then
  skip "ssh-audit (module ssh skipped: SKIP_MODULES)"
elif ! timeout 5 bash -c ": >/dev/tcp/127.0.0.1/$sshd_port" 2>/dev/null; then
  fail "sshd is not listening on 127.0.0.1:$sshd_port"
elif command -v ssh-audit >/dev/null; then
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
  # `|| true`: a missing report file makes awk fail, and the "unknown" fallback below is
  # the intended outcome, not an aborted audit.
  idx="$(awk -F= '/^hardening_index=/{print $2}' /var/log/lynis-report.dat 2>/dev/null | tail -1 || true)"
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
