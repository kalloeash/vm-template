#!/usr/bin/env bash
# 60-sysctl — network + kernel hardening. See docs/HARDENING.md §60-sysctl, tickets/007.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

# Deliberately excluded (documented): disable_ipv6 (breaks dual-stack) and
# unprivileged_userns_clone=0 (breaks rootless containers).
install_file /etc/sysctl.d/99-vmt-hardening.conf - <<'EOF'
# Managed by vm-template (60-sysctl).
# --- network ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
# --- kernel ---
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
# --- filesystem ---
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF

conf=/etc/sysctl.d/99-vmt-hardening.conf
conf_changed=$VMT_FILE_CHANGED

# Read the live value of every key this file sets, so a change can be reported only when
# one actually moved. Keys the kernel does not expose read as empty, consistently.
live_values() {
  local key
  while read -r key _; do
    [[ -n $key && $key != \#* ]] || continue
    printf '%s=%s\n' "$key" "$(sysctl -n "$key" 2>/dev/null || true)"
  done < <(grep -E '^[a-z]' "$conf")
}

if [[ $DRY_RUN == 1 ]]; then
  log_ok "sysctl --system (dry-run)"
elif is_wsl; then
  log_warn "WSL shares the host kernel — wrote the file but skipping 'sysctl --system'"
else
  # Apply on every run so the kernel converges after a reboot or an outside change, but
  # report CHANGED only when the file changed or a value actually moved. Reporting a
  # change unconditionally is what made "a second run is all OK" untrue.
  before="$(live_values)"
  # -e: ignore unknown keys instead of aborting. The Raspberry Pi kernel
  # (linux-raspi) and other non-generic kernels may not expose every key.
  sysctl -e --system >/dev/null
  after="$(live_values)"
  if [[ $conf_changed == 1 || $before != "$after" ]]; then
    log_changed "sysctl values applied (unknown keys ignored)"
  else
    log_ok "sysctl values already applied"
  fi
fi
