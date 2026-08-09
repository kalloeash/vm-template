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

if [[ $DRY_RUN == 1 ]]; then
  log_ok "sysctl --system (dry-run)"
elif is_wsl; then
  log_warn "WSL shares the host kernel — wrote the file but skipping 'sysctl --system'"
else
  # -e: ignore unknown keys instead of aborting. The Raspberry Pi kernel
  # (linux-raspi) and other non-generic kernels may not expose every key.
  sysctl -e --system >/dev/null
  log_changed "sysctl values applied (unknown keys ignored)"
fi
