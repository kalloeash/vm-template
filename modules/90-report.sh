#!/usr/bin/env bash
# 90-report — verification summary. With AUDIT_ONLY=1 (make audit) it changes nothing.
# See docs/HARDENING.md §90-report and tickets/009.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root

AUDIT_ONLY="${AUDIT_ONLY:-0}"
echo "==================== vm-template report ===================="
echo "host: $(hostname)   distro: $os_id $os_codename$(is_wsl && echo '   (WSL)')"

check() { # check "label" test-command...
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then printf '  [ ok ] %s\n' "$label"; else printf '  [MISS] %s\n' "$label"; fi
}

echo "--- state checks ---"
check "password SSH disabled" bash -c "sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'"
check "root SSH disabled" bash -c "sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'"
check "ufw active" bash -c "ufw status 2>/dev/null | grep -qi '^Status: active'"
check "fail2ban sshd jail" bash -c "fail2ban-client status sshd 2>/dev/null"
check "unattended-upgrades enabled" systemctl is-enabled unattended-upgrades
check "sysctl rp_filter" bash -c "[[ \$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null) == 1 ]]"
check "docker installed" docker --version
check "journald persistent" bash -c "grep -qE '^Storage=persistent' /etc/systemd/journald.conf"

echo "--- ssh-audit ---"
if command -v ssh-audit >/dev/null; then
  ssh-audit -l warn 127.0.0.1 2>/dev/null | grep -E '^\(gen\)|fail|warn' | head -20 \
    || echo "  ssh-audit ran (no warn/fail lines)"
else
  echo "  ssh-audit not installed (pip install ssh-audit) — skipped"
fi

echo "--- Lynis hardening index ---"
if command -v lynis >/dev/null; then
  lynis audit system --quick --quiet >/tmp/vmt-lynis.log 2>&1 || true
  idx="$(awk -F'[: ]+' '/Hardening index/{print $NF}' /var/log/lynis-report.dat 2>/dev/null | tail -1)"
  warns="$(grep -c '^warning\[\]' /var/log/lynis-report.dat 2>/dev/null || echo '?')"
  echo "  hardening index: ${idx:-unknown} (target >= 75; fresh images ~50-65)"
  echo "  open warnings:   ${warns} (address warnings before chasing the score)"
else
  echo "  lynis not installed (apt-get install lynis) — skipped"
fi

# Per-module CHANGED/OK lines are printed by each module as it runs; this report
# only summarizes end-state, so it does not re-total them (separate processes).
[[ -f /var/run/reboot-required ]] && echo "NOTE: reboot required (pending kernel/libc update)"
echo "============================================================"
