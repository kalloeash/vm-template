#!/usr/bin/env bash
# 10-update — full upgrade, unattended-upgrades policy, needrestart, time sync.
# See docs/HARDENING.md §10-update and tickets/002.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

export DEBIAN_FRONTEND=noninteractive

# --- apt update + upgrade (keep local config files on conflict) --------------
# Ask apt what it would do before doing it: on a converged host there is nothing to
# upgrade, and reporting CHANGED anyway is what made "second run is all OK" untrue.
# `apt-get -s` prints one `Inst ` line per package it would touch, in any locale.
apt_upgrade_opts=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
if [[ $DRY_RUN == 1 ]]; then
  log_changed "apt update + dist-upgrade (dry-run)"
else
  apt-get update -qq
  pending="$(apt-get -s "${apt_upgrade_opts[@]}" dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)"
  if ((pending == 0)); then
    log_ok "no pending package upgrades"
  else
    apt-get -y "${apt_upgrade_opts[@]}" dist-upgrade >/dev/null
    log_changed "apt dist-upgrade applied ($pending package(s))"
  fi
fi

apt_install unattended-upgrades needrestart
# audit-suggested hygiene: PAM per-session tmp, package verification + versions
apt_install libpam-tmpdir debsums apt-show-versions

# --- unattended-upgrades policy ----------------------------------------------
# Ubuntu/Debian ship -security auto; we also enable -updates, kernel/dep cleanup,
# and an auto-reboot window. Kali is rolling (no -security pocket) so we keep the
# origin minimal and leave auto-reboot off by default.
reboot_flag="true"
reboot_time="04:00"
[[ $os_id == kali ]] && reboot_flag="false"

# The ${distro_id}/${distro_codename} tokens are apt-config placeholders expanded
# by unattended-upgrade, not by the shell — single quotes are intentional (SC2016 off).
# shellcheck disable=SC2016
case "$os_id" in
  ubuntu) origins='        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
        "${distro_id}:${distro_codename}-updates";' ;;
  debian) origins='        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates";' ;;
  kali) origins='        "origin=Kali,codename=kali-rolling";' ;;
esac

install_file /etc/apt/apt.conf.d/52-vmt-autoupgrade - <<EOF
// Managed by vm-template (10-update). Overrides 50unattended-upgrades in lex order.
Unattended-Upgrade::Allowed-Origins {
$origins
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$reboot_flag";
Unattended-Upgrade::Automatic-Reboot-Time "$reboot_time";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

ensure_service_enabled unattended-upgrades
log_ok "unattended-upgrades policy in place (reboot=$reboot_flag)"

# --- needrestart: restart daemons automatically after library upgrades -------
install_file /etc/needrestart/conf.d/vmt.conf - <<'EOF'
# Managed by vm-template: restart services automatically (no interactive prompt).
$nrconf{restart} = 'a';
EOF

# --- time sync ---------------------------------------------------------------
if [[ $DRY_RUN != 1 ]] && ! is_wsl; then
  if systemctl is-active --quiet systemd-timesyncd 2>/dev/null \
    || systemctl is-active --quiet chrony 2>/dev/null; then
    log_ok "time sync active"
  elif systemctl enable --now systemd-timesyncd >/dev/null 2>&1; then
    log_changed "enabled systemd-timesyncd"
  else
    log_warn "no time sync service active — check manually"
  fi
else
  log_ok "time sync check skipped (dry-run/WSL)"
fi
