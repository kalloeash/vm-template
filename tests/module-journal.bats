#!/usr/bin/env bats
# 80-auditd (journald part) and the audit's journald check. JOURNAL_STORAGE=volatile keeps
# the journal in RAM for devices on flash media. See tickets/016.

setup() {
  load helpers/common
  require_userns
  setup_stubs
  JDIR="$BATS_TEST_TMPDIR/journald"
  mkdir -p "$JDIR"
  CONF="$JDIR/journald.conf"
  DROPIN="$JDIR/50-vmt-volatile.conf"
  printf '[Journal]\n#Storage=auto\n' >"$CONF"
  export VMT_JOURNALD_CONF="$CONF" VMT_JOURNALD_DROPIN="$DROPIN"
}

run_audit_journal() {
  stub_recording sshd 1
  stub_recording ufw 1
  stub_recording fail2ban-client 0
  stub_recording systemctl 0
  stub_recording lynis 0
  stub_recording ssh-audit 0
  run unshare -r env PATH="$STUB_BIN:$PATH" DRY_RUN=0 AUDIT_ONLY=1 \
    VMT_JOURNALD_CONF="$CONF" VMT_JOURNALD_DROPIN="$DROPIN" "$@" \
    bash "$REPO_ROOT/modules/90-report.sh"
}

@test "default stays persistent: the main file is edited as before" {
  run run_module 80-auditd
  [ "$status" -eq 0 ]
  assert_output_matches 'would set journald Storage=persistent'
  refute_output_matches 'volatile'
}

@test "JOURNAL_STORAGE=persistent is the same as the default" {
  run run_module 80-auditd JOURNAL_STORAGE=persistent
  [ "$status" -eq 0 ]
  assert_output_matches 'would set journald Storage=persistent'
}

@test "volatile writes a drop-in with the default 32M cap and leaves the main file alone" {
  run run_module 80-auditd JOURNAL_STORAGE=volatile VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  assert_output_matches "$DROPIN"
  assert_output_matches 'Storage=volatile'
  assert_output_matches 'RuntimeMaxUse=32M'
  refute_output_matches 'Storage=persistent'
}

@test "the volatile cap is configurable" {
  run run_module 80-auditd JOURNAL_STORAGE=volatile JOURNAL_VOLATILE_MAX_USE=64M VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  assert_output_matches 'RuntimeMaxUse=64M'
}

@test "an invalid JOURNAL_STORAGE is rejected" {
  run run_module 80-auditd JOURNAL_STORAGE=auto
  [ "$status" -eq 1 ]
  assert_output_matches 'JOURNAL_STORAGE must be persistent or volatile'
}

@test "an invalid size cap is rejected" {
  run run_module 80-auditd JOURNAL_STORAGE=volatile JOURNAL_VOLATILE_MAX_USE=lots
  [ "$status" -eq 1 ]
  assert_output_matches 'JOURNAL_VOLATILE_MAX_USE must be a size'
}

@test "going back to persistent removes the volatile drop-in" {
  printf '[Journal]\nStorage=volatile\n' >"$DROPIN"
  run run_module 80-auditd JOURNAL_STORAGE=persistent
  [ "$status" -eq 0 ]
  assert_output_matches 'would remove .*50-vmt-volatile.conf'
}

# --- the audit ---------------------------------------------------------------------

@test "audit: persistent is still the mandatory default" {
  printf '[Journal]\nStorage=persistent\n' >"$CONF"
  run_audit_journal
  assert_output_matches '\[ ok \] journald persistent'
}

@test "audit: persistent fails when the journal is configured volatile" {
  printf '[Journal]\nStorage=volatile\n' >"$CONF"
  run_audit_journal
  assert_output_matches '\[MISS\] journald persistent'
}

@test "audit: volatile with the cap is accepted when JOURNAL_STORAGE=volatile" {
  printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=32M\n' >"$DROPIN"
  run_audit_journal JOURNAL_STORAGE=volatile
  assert_output_matches '\[ ok \] journald volatile, capped at 32M'
  refute_output_matches '\[MISS\] journald'
}

@test "audit: volatile is a failure when the drop-in is missing" {
  run_audit_journal JOURNAL_STORAGE=volatile
  assert_output_matches '\[MISS\] journald volatile'
}

@test "audit: volatile is a failure when the cap differs from the configured one" {
  printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=500M\n' >"$DROPIN"
  run_audit_journal JOURNAL_STORAGE=volatile
  assert_output_matches '\[MISS\] journald volatile'
}

@test "audit: an invalid JOURNAL_STORAGE is rejected" {
  run_audit_journal JOURNAL_STORAGE=maybe
  [ "$status" -eq 1 ]
  assert_output_matches 'JOURNAL_STORAGE must be persistent or volatile'
}
