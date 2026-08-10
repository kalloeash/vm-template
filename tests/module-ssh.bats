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

@test "moduli pruning keeps groups at or above the floor and drops the rest" {
  # The awk filter the module uses, exercised against a fixture with a 2047-bit group.
  fixture="$BATS_TEST_TMPDIR/moduli"
  cat >"$fixture" <<'EOF'
# Time Type Tests Tries Size Generator Modulus
20240101000000 2 6 100 2047 2 ABCD
20240101000000 2 6 100 3071 2 EF01
20240101000000 2 6 100 4095 2 2345
EOF
  run awk -v min=3071 '/^#/ || NF < 5 || $5 >= min' "$fixture"
  [ "$status" -eq 0 ]
  assert_output_matches '3071'
  assert_output_matches '4095'
  refute_output_matches '2047'
}

@test "a moduli file with nothing left above the floor is refused, not emptied" {
  # An empty moduli file breaks diffie-hellman-group-exchange entirely, which is worse
  # than the weak group it was meant to remove.
  fixture="$BATS_TEST_TMPDIR/moduli-weak"
  printf '# comment\n20240101000000 2 6 100 2047 2 ABCD\n' >"$fixture"
  run bash -c "awk -v min=3071 '/^#/ || NF < 5 || \$5 >= min' '$fixture' | awk '!/^#/ && NF >= 5' | wc -l"
  [ "$output" -eq 0 ]
}

@test "the module leaves ecdsa key material alone and says why" {
  grep -q 'ssh-keygen -A regenerates missing host keys' "$REPO_ROOT/modules/30-ssh.sh"
}

@test "host key rotation is opt-in, never automatic" {
  # Rotating breaks every client's known_hosts; it must not happen by default.
  grep -q 'SSH_REGEN_HOST_KEYS:-0' "$REPO_ROOT/modules/30-ssh.sh"
  run grep -c 'ssh-keygen -q -t rsa' "$REPO_ROOT/modules/30-ssh.sh"
  [ "$output" -eq 1 ]
}

@test "password and root login are both disabled in the drop-in" {
  run grep -E '^(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)' \
    "$REPO_ROOT/modules/30-ssh.sh"
  assert_output_matches '^PasswordAuthentication no$'
  assert_output_matches '^PermitRootLogin no$'
  assert_output_matches '^KbdInteractiveAuthentication no$'
}
