#!/usr/bin/env bats
# SKIP_MODULES — validation, the modules honouring it, and the audit reporting the skipped
# controls as [skip] instead of failures. See tickets/016.

setup() {
  load helpers/common
  require_userns
  setup_stubs
}

# Run the audit for real (DRY_RUN=0) under fake root. Everything it would ask the host is
# stubbed, so the outcome does not depend on what the runner has installed. The result is
# not a pass: most controls are [MISS] on a bare runner, which is what the tests read.
run_audit() {
  stub_recording sshd 1
  stub_recording ufw 1
  stub_recording fail2ban-client 0
  stub_recording systemctl 0
  stub_recording lynis 0
  stub_recording ssh-audit 0
  stub_recording docker 1
  run unshare -r env PATH="$STUB_BIN:$PATH" DRY_RUN=0 AUDIT_ONLY=1 "$@" \
    bash "$REPO_ROOT/modules/90-report.sh"
}

# --- validation -----------------------------------------------------------------

@test "preflight rejects an unknown module name" {
  run run_module 00-preflight SKIP_MODULES="dockr"
  [ "$status" -eq 1 ]
  assert_output_matches "SKIP_MODULES: unknown module 'dockr'"
}

@test "the always-on modules cannot be skipped" {
  run run_module 00-preflight SKIP_MODULES="preflight"
  [ "$status" -eq 1 ]
  run run_module 00-preflight SKIP_MODULES="report"
  [ "$status" -eq 1 ]
}

@test "one bad name in a list fails the whole list" {
  run run_module 00-preflight "SKIP_MODULES=docker nonsense"
  [ "$status" -eq 1 ]
  assert_output_matches "unknown module 'nonsense'"
}

@test "a valid list passes preflight validation" {
  # preflight needs systemd; where it is missing the failure is the systemd guard, not ours
  run run_module 00-preflight "SKIP_MODULES=docker auditd"
  refute_output_matches 'SKIP_MODULES: unknown module'
}

@test "the audit rejects an unknown module name too" {
  run_audit SKIP_MODULES=dockr
  [ "$status" -eq 1 ]
  assert_output_matches "SKIP_MODULES: unknown module 'dockr'"
}

@test "preflight rejects a bad value for every other new variable before anything runs" {
  run run_module 00-preflight UPDATE_SKIP_DIST_UPGRADE=2
  [ "$status" -eq 1 ]
  assert_output_matches 'UPDATE_SKIP_DIST_UPGRADE must be 0 or 1'
  run run_module 00-preflight JOURNAL_STORAGE=ram
  [ "$status" -eq 1 ]
  assert_output_matches 'JOURNAL_STORAGE must be persistent or volatile'
  run run_module 00-preflight 'UPGRADE_HOLD_PACKAGES=ok-pkg Bad_Name'
  [ "$status" -eq 1 ]
  assert_output_matches "UPGRADE_HOLD_PACKAGES: 'Bad_Name'"
  run run_module 00-preflight FAIL2BAN_IGNOREIP=nothost
  [ "$status" -eq 1 ]
  assert_output_matches "FAIL2BAN_IGNOREIP: 'nothost'"
  run run_module 00-preflight SSH_ALLOW_FROM=nothost
  [ "$status" -eq 1 ]
  assert_output_matches "SSH_ALLOW_FROM: 'nothost'"
}

# --- harden honours it ------------------------------------------------------------

@test "a skipped module does nothing and says so" {
  run run_module 70-docker SKIP_MODULES=docker
  [ "$status" -eq 0 ]
  assert_output_matches 'docker skipped \(SKIP_MODULES\)'
  refute_output_matches 'Docker apt repo|daemon.json'
}

@test "a module that is not in the list still runs" {
  run run_module 70-docker SKIP_MODULES=auditd
  [ "$status" -eq 0 ]
  refute_output_matches 'docker skipped'
  assert_output_matches 'daemon.json'
}

@test "every known module honours the skip" {
  for name in update user ssh firewall fail2ban sysctl hardening docker auditd; do
    mod="$(basename "$(ls "$REPO_ROOT"/modules/[0-9][0-9]-"$name".sh)" .sh)"
    run run_module "$mod" SKIP_MODULES="$name"
    [ "$status" -eq 0 ] || {
      echo "$mod failed: $output" >&2
      return 1
    }
    assert_output_matches "$name skipped \(SKIP_MODULES\)"
  done
}

@test "the Makefile exports SKIP_MODULES to the modules" {
  grep -qE '^export SKIP_MODULES' "$REPO_ROOT/Makefile"
}

# --- audit reports skipped controls as [skip] ---------------------------------------

@test "audit: without SKIP_MODULES the docker line is a note, not a skip" {
  run_audit
  assert_output_matches '\[note\] docker installed'
  refute_output_matches 'module docker skipped'
}

@test "audit: a skipped module is reported [skip] with the reason" {
  run_audit SKIP_MODULES=docker
  assert_output_matches '\[skip\] docker installed \(module docker skipped: SKIP_MODULES\)'
  refute_output_matches '\[note\] docker installed'
}

@test "audit: skipped ssh controls are [skip], not [MISS]" {
  run_audit SKIP_MODULES=ssh
  assert_output_matches '\[skip\] password SSH disabled \(module ssh skipped'
  assert_output_matches '\[skip\] root SSH disabled \(module ssh skipped'
  assert_output_matches '\[skip\] ssh-audit \(module ssh skipped'
  refute_output_matches '\[MISS\] (password|root) SSH disabled'
}

@test "audit: the same controls are [MISS] when ssh is not skipped" {
  run_audit
  assert_output_matches '\[MISS\] password SSH disabled'
  [ "$status" -eq 1 ]
}

@test "audit: skipped controls are counted as skipped, not failed" {
  run_audit SKIP_MODULES="ssh firewall fail2ban update user hardening docker auditd sysctl"
  assert_output_matches 'mandatory: [0-9]+ passed, 0 failed, [0-9]+ skipped'
  [ "$status" -eq 0 ]
}

# --- ADMIN_SUDO=keep in the audit ----------------------------------------------------

@test "the audit counts 'can escalate to root' for the default" {
  run_audit ADMIN_USER=root
  assert_output_matches '\[(MISS| ok )\] root can escalate to root$'
}

@test "with ADMIN_SUDO=keep the escalation control is informational" {
  run_audit ADMIN_USER=vmtnouser ADMIN_SUDO=keep
  assert_output_matches '\[note\] vmtnouser can escalate to root \(ADMIN_SUDO=keep'
  refute_output_matches '\[MISS\] vmtnouser can escalate'
}

@test "the audit rejects an unknown ADMIN_SUDO" {
  run_audit ADMIN_SUDO=maybe
  [ "$status" -eq 1 ]
  assert_output_matches 'ADMIN_SUDO must be keep, nopasswd or password'
}

@test "preflight rejects bad ADMIN_SUDO and UPGRADE_REMOVE_UNUSED_KERNELS" {
  run run_module 00-preflight ADMIN_SUDO=maybe
  [ "$status" -eq 1 ]
  run run_module 00-preflight UPGRADE_REMOVE_UNUSED_KERNELS=2
  [ "$status" -eq 1 ]
  assert_output_matches 'UPGRADE_REMOVE_UNUSED_KERNELS must be 0 or 1'
}
