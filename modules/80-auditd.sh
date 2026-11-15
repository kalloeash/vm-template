#!/usr/bin/env bash
# 80-auditd — audit trail (TIER=full) + persistent journald (always).
# See docs/HARDENING.md §80-auditd and tickets/009.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali
skip_if_requested auditd

# --- journald storage (base tier) ---------------------------------------------
# Default JOURNAL_STORAGE=persistent: logs survive reboots for incident review, written
# into the main journald.conf as before. JOURNAL_STORAGE=volatile keeps the journal in
# RAM (/run/log/journal), capped at JOURNAL_VOLATILE_MAX_USE, for devices on flash media
# where constant log writes wear the card; the trade is that logs are gone after a
# reboot. Volatile goes in a drop-in, which overrides the main file and is removed when
# the mode goes back to persistent.
validate_journal
journald_dropin="$VMT_JOURNALD_DROPIN"

restart_journald() { is_wsl || systemctl restart systemd-journald >/dev/null 2>&1 || true; }

if [[ $JOURNAL_STORAGE == volatile ]]; then
  install_file "$journald_dropin" - <<EOF
# Managed by vm-template (80-auditd). RAM-only journal, capped.
[Journal]
Storage=volatile
RuntimeMaxUse=$JOURNAL_VOLATILE_MAX_USE
EOF
  if [[ $VMT_FILE_CHANGED == 1 && $DRY_RUN != 1 ]]; then restart_journald; fi
  log_ok "journald volatile (RuntimeMaxUse=$JOURNAL_VOLATILE_MAX_USE); logs do not survive a reboot"
elif [[ -f $journald_dropin ]]; then
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "would remove $journald_dropin: back to persistent (dry-run)"
  else
    rm -f "$journald_dropin"
    restart_journald
    log_changed "removed $journald_dropin: journald back to the main file's setting"
  fi
fi

if [[ $JOURNAL_STORAGE == persistent && -f $VMT_JOURNALD_CONF ]]; then
  if grep -qE '^\s*Storage=persistent' "$VMT_JOURNALD_CONF"; then
    log_ok "journald already persistent"
  elif [[ $DRY_RUN == 1 ]]; then
    log_changed "would set journald Storage=persistent (dry-run)"
  else
    install -d -m 0755 /var/log/journal
    sed -i 's/^\s*#\?\s*Storage=.*/Storage=persistent/' "$VMT_JOURNALD_CONF"
    grep -qE '^Storage=persistent' "$VMT_JOURNALD_CONF" ||
      echo 'Storage=persistent' >>"$VMT_JOURNALD_CONF"
    restart_journald
    log_changed "journald set to persistent"
  fi
fi

# --- auditd is the optional full tier ----------------------------------------
if [[ "${TIER:-base}" != full ]]; then
  log_ok "auditd skipped (base tier; set TIER=full to enable)"
  # runs as a sourced-or-executed script; both exits are intentional
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

apt_install auditd audispd-plugins

install_file /etc/audit/rules.d/99-vmt.rules - <<'EOF'
# Managed by vm-template (80-auditd). Minimal high-signal ruleset.
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /etc/docker/daemon.json -p wa -k docker
-a always,exit -F arch=b64 -F euid=0 -S execve -k root-exec
EOF

rules_changed=$VMT_FILE_CHANGED

if [[ $DRY_RUN != 1 ]] && ! is_wsl; then
  ensure_service_enabled auditd
  # Loading the rules is only a change when the rule file changed or the kernel has
  # none loaded; `augenrules --load` on every run reported a change that had not
  # happened.
  # `auditctl -l` prints "No rules" (not nothing) when the kernel has none, so match
  # actual rule lines instead of any output.
  loaded=0
  auditctl -l 2>/dev/null | grep -qE '^-' && loaded=1
  if [[ $rules_changed == 1 || $loaded == 0 ]]; then
    augenrules --load >/dev/null 2>&1 || log_warn "augenrules load failed"
    log_changed "auditd rules loaded"
  else
    log_ok "auditd rules already loaded"
  fi
else
  log_ok "auditd rule load skipped (dry-run/WSL)"
fi
