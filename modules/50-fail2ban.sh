#!/usr/bin/env bash
# 50-fail2ban — sshd jail, systemd backend, incremental bans.
# See docs/HARDENING.md §50-fail2ban and tickets/006.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

skip_if_requested fail2ban

# Addresses or CIDRs fail2ban never bans (space separated). Default empty: the jail keeps
# fail2ban's own default (127.0.0.1/8 ::1). A single-admin LAN device sets the admin's
# machine here so a few mistyped passphrases cannot ban the only way in.
FAIL2BAN_IGNOREIP="${FAIL2BAN_IGNOREIP:-}"
validate_address_list FAIL2BAN_IGNOREIP "$FAIL2BAN_IGNOREIP"
ignoreip_line=""
[[ -z $FAIL2BAN_IGNOREIP ]] || ignoreip_line="ignoreip = 127.0.0.1/8 ::1 $FAIL2BAN_IGNOREIP"

apt_install fail2ban

# backend = systemd is mandatory on 24.04/Debian 13: sshd logs to the journal,
# not /var/log/auth.log, so the default `auto` backend fails to start the jail.
# allowipv6 = auto silences the dual-stack warning. Only a jail.d drop-in — never
# a full jail.conf -> jail.local copy.
jail="# Managed by vm-template (50-fail2ban).
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
bantime.maxtime   = 5w"
[[ -z $ignoreip_line ]] || jail+=$'\n'"$ignoreip_line"
install_file /etc/fail2ban/jail.d/sshd.local - <<<"$jail"

jail_changed=$VMT_FILE_CHANGED

if [[ $DRY_RUN == 1 ]]; then
  log_ok "fail2ban enable + start (dry-run)"
elif is_wsl && [[ ! -d /run/systemd/system ]]; then
  log_warn "WSL without systemd: skipping fail2ban start"
else
  systemctl is-enabled --quiet fail2ban 2>/dev/null || systemctl enable fail2ban >/dev/null 2>&1 || true
  # config-test on every run so a jail broken by something else still fails loudly
  if ! fail2ban-client -t >/tmp/vmt-f2b.err 2>&1; then
    cat /tmp/vmt-f2b.err >&2
    die "fail2ban config test failed"
  fi
  # Restart only when there is a reason to: a changed jail, or a dead service.
  # Restarting every run reported a change that had not happened and dropped the
  # in-memory ban list each time.
  if [[ $jail_changed == 1 ]]; then
    systemctl restart fail2ban
    log_changed "fail2ban restarted (jail config changed)"
  elif ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    systemctl start fail2ban
    log_changed "fail2ban started"
  else
    log_ok "fail2ban running with the sshd jail"
  fi
fi
