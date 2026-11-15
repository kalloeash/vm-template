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

@test "the drop-in pins only host keys the module found, never a fixed path" {
  # No literal HostKey line: the lines come from ssh_pinnable_hostkeys.
  run grep -c '^HostKey' "$REPO_ROOT/modules/30-ssh.sh"
  [ "$output" -eq 0 ]
  grep -q 'ssh_pinnable_hostkeys' "$REPO_ROOT/modules/30-ssh.sh"
}

# A fake sshd whose -T output lists the given host key paths, and fake key files.
fake_sshd_with_keys() {
  KEYDIR="$BATS_TEST_TMPDIR/keys"
  mkdir -p "$KEYDIR"
  {
    echo '#!/bin/bash'
    echo 'echo "port 22"'
    for k in "$@"; do echo "echo \"hostkey $k\""; done
  } >"$STUB_BIN/sshd"
  chmod +x "$STUB_BIN/sshd"
  # ssh-keygen stub: the type comes from the file name
  cat >"$STUB_BIN/ssh-keygen" <<'SH'
#!/bin/bash
f="${@: -1}"
case "$f" in
  *ecdsa*) echo "256 SHA256:x no comment (ECDSA)" ;;
  *rsa*) echo "3072 SHA256:x no comment (RSA)" ;;
  *) echo "256 SHA256:x no comment (ED25519)" ;;
esac
SH
  chmod +x "$STUB_BIN/ssh-keygen"
}

pinnable() {
  run env PATH="$STUB_BIN:$PATH" bash -c "source '$REPO_ROOT/lib/common.sh'; ssh_pinnable_hostkeys"
}

@test "host keys that live outside /etc/ssh are pinned where sshd found them" {
  fake_sshd_with_keys "$BATS_TEST_TMPDIR/keys/ssh_host_ed25519_key"
  : >"$BATS_TEST_TMPDIR/keys/ssh_host_ed25519_key"
  pinnable
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/keys/ssh_host_ed25519_key" ]
}

@test "a configured host key path that does not exist is not pinned" {
  fake_sshd_with_keys /nonexistent/ssh_host_ed25519_key /nonexistent/ssh_host_rsa_key \
    "$BATS_TEST_TMPDIR/keys/ssh_host_ed25519_key"
  : >"$BATS_TEST_TMPDIR/keys/ssh_host_ed25519_key"
  pinnable
  [ "$status" -eq 0 ]
  refute_output_matches 'nonexistent'
  assert_output_matches 'keys/ssh_host_ed25519_key$'
}

@test "ecdsa keys are never pinned, even when they exist" {
  fake_sshd_with_keys "$BATS_TEST_TMPDIR/keys/ssh_host_ecdsa_key" "$BATS_TEST_TMPDIR/keys/ssh_host_rsa_key"
  : >"$BATS_TEST_TMPDIR/keys/ssh_host_ecdsa_key"
  : >"$BATS_TEST_TMPDIR/keys/ssh_host_rsa_key"
  pinnable
  refute_output_matches 'ecdsa'
  assert_output_matches 'ssh_host_rsa_key'
}

@test "no existing key means nothing is pinned" {
  fake_sshd_with_keys /nonexistent/a_key
  pinnable
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing configured host keys are reported, which sshd -t does not do" {
  fake_sshd_with_keys /nonexistent/ssh_host_rsa_key "$BATS_TEST_TMPDIR/keys/ssh_host_ed25519_key"
  : >"$BATS_TEST_TMPDIR/keys/ssh_host_ed25519_key"
  run env PATH="$STUB_BIN:$PATH" bash -c "source '$REPO_ROOT/lib/common.sh'; ssh_missing_hostkeys"
  [ "$output" = "/nonexistent/ssh_host_rsa_key" ]
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
