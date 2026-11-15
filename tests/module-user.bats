#!/usr/bin/env bats
# The crypt(3) hash fixtures below are single-quoted on purpose — `$6$` is the algorithm
# marker, not a variable (SC2016 off).
# shellcheck disable=SC2016
#
# 20-user — the privilege model. Every case here is a decision the module makes before
# it writes anything, so DRY_RUN=1 exercises all of it. See tickets/003.

setup() {
  load helpers/common
  require_userns
  setup_stubs
  # a name that cannot exist on the runner, so the "create" path is the one under test
  NEWUSER="vmttest$$"
}

@test "key-only account gets a NOPASSWD sudoers drop-in" {
  run run_module 20-user "ADMIN_USER=$NEWUSER"
  [ "$status" -eq 0 ]
  assert_output_matches 'would lock password'
  assert_output_matches 'sudo without password'
  assert_output_matches "/etc/sudoers.d/90-vmt-$NEWUSER"
}

@test "SUDO_NOPASSWD=0 without a password is refused, not shipped" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" SUDO_NOPASSWD=0
  [ "$status" -eq 1 ]
  assert_output_matches 'FATAL'
  assert_output_matches 'no usable password'
  assert_output_matches 'ADMIN_PASSWORD_HASH'
  # and it must not have written a sudoers file on the way out
  refute_output_matches '^CHANGED: /etc/sudoers.d/'
}

@test "a supplied password hash flips the default to password-required sudo" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" \
    'ADMIN_PASSWORD_HASH=$6$saltsalt$0123456789abcdef'
  [ "$status" -eq 0 ]
  assert_output_matches 'would set .* password from ADMIN_PASSWORD_HASH'
  assert_output_matches 'sudo requires .* password'
  refute_output_matches '/etc/sudoers\.d/90-vmt-'
}

@test "a plaintext password is rejected rather than written to /etc/shadow" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" ADMIN_PASSWORD_HASH=hunter2
  [ "$status" -eq 1 ]
  assert_output_matches 'crypt\(3\) hash'
}

@test "ADMIN_USER is validated before it reaches a sudoers file" {
  run run_module 20-user 'ADMIN_USER=evil ALL=(ALL) NOPASSWD:ALL #'
  [ "$status" -eq 1 ]
  assert_output_matches 'invalid ADMIN_USER'
}

@test "an explicit SUDO_NOPASSWD=1 alongside a hash is honored and explained" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" SUDO_NOPASSWD=1 \
    'ADMIN_PASSWORD_HASH=$6$saltsalt$0123456789abcdef'
  [ "$status" -eq 0 ]
  assert_output_matches 'overriding the password model'
}

@test "a missing authorized_keys is a warning, not a failure" {
  run run_module 20-user "ADMIN_USER=$NEWUSER"
  [ "$status" -eq 0 ]
  assert_output_matches 'no authorized_keys'
}

# --- ADMIN_SUDO ----------------------------------------------------------------

@test "ADMIN_SUDO=keep writes no sudoers file and adds no group" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" ADMIN_SUDO=keep
  [ "$status" -eq 0 ]
  assert_output_matches 'ADMIN_SUDO=keep'
  refute_output_matches '/etc/sudoers\.d/90-vmt-'
  refute_output_matches 'add .* to sudo'
  refute_output_matches 'sudo without password'
}

@test "ADMIN_SUDO=keep is not stopped by the missing password check" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" ADMIN_SUDO=keep SUDO_NOPASSWD=0
  [ "$status" -eq 0 ]
}

@test "ADMIN_SUDO=nopasswd writes the NOPASSWD drop-in even with a password" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" ADMIN_SUDO=nopasswd \
    'ADMIN_PASSWORD_HASH=$6$saltsalt$0123456789abcdef'
  [ "$status" -eq 0 ]
  assert_output_matches "/etc/sudoers.d/90-vmt-$NEWUSER"
}

@test "ADMIN_SUDO=password without a password is refused" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" ADMIN_SUDO=password
  [ "$status" -eq 1 ]
  assert_output_matches 'no usable password'
}

@test "an unknown ADMIN_SUDO value is rejected" {
  run run_module 20-user "ADMIN_USER=$NEWUSER" ADMIN_SUDO=yes
  [ "$status" -eq 1 ]
  assert_output_matches 'ADMIN_SUDO must be keep, nopasswd or password'
}

@test "unset ADMIN_SUDO behaves as before: key-only account gets NOPASSWD" {
  run run_module 20-user "ADMIN_USER=$NEWUSER"
  assert_output_matches "/etc/sudoers.d/90-vmt-$NEWUSER"
}
