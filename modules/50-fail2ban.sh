#!/usr/bin/env bash
# 50-fail2ban — sshd jail, systemd backend, incremental bans.
# See docs/HARDENING.md §50-fail2ban and tickets/006.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

apt_install fail2ban

# backend = systemd is mandatory on 24.04/Debian 13: sshd logs to the journal,
# not /var/log/auth.log, so the default `auto` backend fails to start the jail.
# allowipv6 = auto silences the dual-stack warning. Only a jail.d drop-in — never
# a full jail.conf -> jail.local copy.
install_file /etc/fail2ban/jail.d/sshd.local - <<'EOF'
# Managed by vm-template (50-fail2ban).
[DEFAULT]
allowipv6 = auto

[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 3
findtime = 600
bantime  = 3600
bantime.increment = true
bantime.factor    = 24
bantime.maxtime   = 5w
EOF

if [[ $DRY_RUN == 1 ]]; then
  log_ok "fail2ban enable + start (dry-run)"
elif is_wsl && [[ ! -d /run/systemd/system ]]; then
  log_warn "WSL without systemd: skipping fail2ban start"
else
  systemctl enable fail2ban >/dev/null 2>&1 || true
  # config-test before (re)start so a bad jail fails loudly, not silently
  if fail2ban-client -t >/tmp/vmt-f2b.err 2>&1; then
    systemctl restart fail2ban
    log_changed "fail2ban restarted with sshd jail"
  else
    cat /tmp/vmt-f2b.err >&2
    die "fail2ban config test failed"
  fi
fi
