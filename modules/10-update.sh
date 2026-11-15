#!/usr/bin/env bash
# 10-update — full upgrade, unattended-upgrades policy, needrestart, time sync.
# See docs/HARDENING.md §10-update and tickets/002.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

export DEBIAN_FRONTEND=noninteractive
skip_if_requested update

# UPDATE_SKIP_DIST_UPGRADE=1 skips the immediate dist-upgrade. A freshly built image that
# is still booting should not block on a long upgrade; unattended-upgrades picks the
# updates up later, within its own origin and hold rules. Default 0 = upgrade now.
UPDATE_SKIP_DIST_UPGRADE="${UPDATE_SKIP_DIST_UPGRADE:-0}"
validate_flag01 UPDATE_SKIP_DIST_UPGRADE "$UPDATE_SKIP_DIST_UPGRADE"
# Space-separated package name globs kept out of unattended upgrades (kernel, firmware,
# bootloader on a device that cannot be recovered remotely). Default empty = no blacklist.
UPGRADE_HOLD_PACKAGES="${UPGRADE_HOLD_PACKAGES:-}"
hold_regexes="$(glob_to_regex "$UPGRADE_HOLD_PACKAGES")"
# 1 (default) lets unattended-upgrades remove old kernel packages. Set 0 on a host that
# holds kernel packages back: the previous kernel is then the only way to roll back.
UPGRADE_REMOVE_UNUSED_KERNELS="${UPGRADE_REMOVE_UNUSED_KERNELS:-1}"
validate_flag01 UPGRADE_REMOVE_UNUSED_KERNELS "$UPGRADE_REMOVE_UNUSED_KERNELS"
remove_kernels="true"
[[ $UPGRADE_REMOVE_UNUSED_KERNELS == 1 ]] || remove_kernels="false"
# Where to look for the Raspberry Pi archive in apt sources (see rpi_archive_configured).
APT_SOURCE_PATHS="${APT_SOURCE_PATHS:-/etc/apt/sources.list /etc/apt/sources.list.d}"

# --- apt update + upgrade (keep local config files on conflict) --------------
# Ask apt what it would do before doing it: on a converged host there is nothing to
# upgrade, and reporting CHANGED anyway is what made "second run is all OK" untrue.
# `apt-get -s` prints one `Inst `/`Remv ` line per package it would touch, in any locale.
apt_upgrade_opts=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
if [[ $UPDATE_SKIP_DIST_UPGRADE == 1 ]]; then
  [[ $DRY_RUN == 1 ]] || apt-get update -qq
  log_ok "dist-upgrade skipped (UPDATE_SKIP_DIST_UPGRADE=1)"
elif [[ $DRY_RUN == 1 ]]; then
  log_changed "apt update + dist-upgrade (dry-run)"
else
  apt-get update -qq
  pending="$(apt-get -s "${apt_upgrade_opts[@]}" dist-upgrade 2>/dev/null | grep -cE '^(Inst|Remv) ' || true)"
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

# Two key names, two syntaxes. Allowed-Origins takes the legacy "Origin:Archive" form
# only; "origin=Debian,codename=..." there makes unattended-upgrade abort with "Unable to
# parse Unattended-Upgrade::Allowed-Origins". The key=value form belongs under
# Origins-Pattern, so Debian and Kali use that. Ubuntu keeps the legacy form.
# The ${distro_id}/${distro_codename} tokens are apt-config placeholders expanded
# by unattended-upgrade, not by the shell — single quotes are intentional (SC2016 off).
origins_key="Allowed-Origins"
[[ $os_id == ubuntu ]] || origins_key="Origins-Pattern"
# shellcheck disable=SC2016
case "$os_id" in
  ubuntu) origins='        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
        "${distro_id}:${distro_codename}-updates";' ;;
  debian) origins='        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates,label=Debian";' ;;
  kali) origins='        "origin=Kali,codename=kali-rolling";' ;;
esac

blacklist_block=""
if [[ -n $hold_regexes ]]; then
  blacklist_block="Unattended-Upgrade::Package-Blacklist {"
  while IFS= read -r rx; do blacklist_block+=$'\n'"    \"$rx\";"; done <<<"$hold_regexes"
  blacklist_block+=$'\n'"};"
fi

policy="// Managed by vm-template (10-update). Overrides 50unattended-upgrades in lex order.
Unattended-Upgrade::$origins_key {
$origins
};"
[[ -z $blacklist_block ]] || policy+=$'\n'"$blacklist_block"
policy+="
Unattended-Upgrade::Remove-Unused-Kernel-Packages \"$remove_kernels\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
Unattended-Upgrade::Automatic-Reboot \"$reboot_flag\";
Unattended-Upgrade::Automatic-Reboot-Time \"$reboot_time\";
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";"
install_file /etc/apt/apt.conf.d/52-vmt-autoupgrade - <<<"$policy"

# --- Raspberry Pi archive origin (separate drop-in) ---------------------------
# archive.raspberrypi.com carries the kernel, firmware and Raspberry Pi packages on
# Raspberry Pi OS. Its trixie Release file (fetched 2026-11-15) says:
#   Origin: Raspberry Pi Foundation   Label: Raspberry Pi Foundation
#   Suite: stable                     Codename: trixie
# Suite is "stable", not the release name, so the pattern matches on codename. The
# drop-in is written only when apt knows the archive: a host without it must not carry
# an origin it cannot match.
rpi_archive_configured() {
  if command -v apt-cache >/dev/null 2>&1 &&
    apt-cache policy 2>/dev/null | grep -qE 'o=Raspberry Pi Foundation|archive\.raspberrypi\.(com|org)'; then
    return 0
  fi
  local p existing=()
  for p in $APT_SOURCE_PATHS; do [[ -e $p ]] && existing+=("$p"); done
  ((${#existing[@]} > 0)) || return 1
  grep -rqsE '^[[:space:]]*(deb|URIs:).*archive\.raspberrypi\.(com|org)' "${existing[@]}"
}

rpi_dropin=/etc/apt/apt.conf.d/53-vmt-raspberrypi-origin
if rpi_archive_configured; then
  # The ${distro_codename} token is expanded by unattended-upgrade, not the shell.
  install_file "$rpi_dropin" - <<'EOF'
// Managed by vm-template (10-update). Adds the Raspberry Pi archive to the origins
// unattended-upgrades may install from. Values are from the archive's Release file.
Unattended-Upgrade::Origins-Pattern:: "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
EOF
elif [[ -f $rpi_dropin ]]; then
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "would remove $rpi_dropin: Raspberry Pi archive no longer configured (dry-run)"
  else
    rm -f "$rpi_dropin"
    log_changed "removed $rpi_dropin: Raspberry Pi archive no longer configured"
  fi
else
  log_ok "Raspberry Pi archive not configured; no extra origin"
fi

ensure_service_enabled unattended-upgrades
log_ok "unattended-upgrades policy in place (reboot=$reboot_flag)"

# --- needrestart: restart daemons automatically after library upgrades -------
install_file /etc/needrestart/conf.d/vmt.conf - <<'EOF'
# Managed by vm-template: restart services automatically (no interactive prompt).
$nrconf{restart} = 'a';
EOF

# --- time sync ---------------------------------------------------------------
if [[ $DRY_RUN != 1 ]] && ! is_wsl; then
  if systemctl is-active --quiet systemd-timesyncd 2>/dev/null ||
    systemctl is-active --quiet chrony 2>/dev/null; then
    log_ok "time sync active"
  elif systemctl enable --now systemd-timesyncd >/dev/null 2>&1; then
    log_changed "enabled systemd-timesyncd"
  else
    log_warn "no time sync service active — check manually"
  fi
else
  log_ok "time sync check skipped (dry-run/WSL)"
fi
