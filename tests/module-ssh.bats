#!/usr/bin/env bats
# 30-ssh — the refusal path. The apply/rollback path needs a real sshd and is tier 3
# (tickets/004 criteria 4 and 6); what is checkable here is that the module will not
# touch sshd_config.d without the lockout guard.

setup() {
  load helpers/common
  require_userns
  setup_stubs
}

@test "without the lockout guard the module refuses and writes nothing" {
  # 00-preflight drops /run/vm-template.lockout-ok; it is absent on a test runner.
  [ ! -f /run/vm-template.lockout-ok ] || skip "lockout guard present on this host"
  run run_module 30-ssh
  [ "$status" -eq 1 ]
  assert_output_matches 'lockout guard not set'
  assert_output_matches 'Refusing to disable password auth'
  refute_output_matches '^CHANGED: /etc/ssh'
}

@test "the drop-in the module would write has no ecdsa host key" {
  # The ecdsa host key is what ssh-audit flags; the drop-in exists to stop offering it.
  run grep -c '^HostKey' "$REPO_ROOT/modules/30-ssh.sh"
  [ "$output" -eq 2 ]
  run grep '^HostKey' "$REPO_ROOT/modules/30-ssh.sh"
  assert_output_matches 'ssh_host_ed25519_key'
  assert_output_matches 'ssh_host_rsa_key'
  refute_output_matches 'ecdsa'
}

@test "password and root login are both disabled in the drop-in" {
  run grep -E '^(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)' \
    "$REPO_ROOT/modules/30-ssh.sh"
  assert_output_matches '^PasswordAuthentication no$'
  assert_output_matches '^PermitRootLogin no$'
  assert_output_matches '^KbdInteractiveAuthentication no$'
}
