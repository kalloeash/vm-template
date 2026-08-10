#!/usr/bin/env bash
# 80-auditd — audit trail (TIER=full) + persistent journald (always).
# See docs/HARDENING.md §80-auditd and tickets/009.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

# --- journald persistence is base-tier (survives reboots for incident review) ---
if [[ -f /etc/systemd/journald.conf ]]; then
  if grep -qE '^\s*Storage=persistent' /etc/systemd/journald.conf; then
    log_ok "journald already persistent"
  elif [[ $DRY_RUN == 1 ]]; then
    log_changed "would set journald Storage=persistent (dry-run)"
  else
    install -d -m 0755 /var/log/journal
    sed -i 's/^\s*#\?\s*Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
    grep -qE '^Storage=persistent' /etc/systemd/journald.conf \
      || echo 'Storage=persistent' >>/etc/systemd/journald.conf
    is_wsl || systemctl restart systemd-journald >/dev/null 2>&1 || true
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
