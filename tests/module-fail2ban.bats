#!/usr/bin/env bats
# 50-fail2ban — the jail drop-in and FAIL2BAN_IGNOREIP. See tickets/016.

setup() {
  load helpers/common
  require_userns
  setup_stubs
}

@test "default: the jail has no ignoreip line" {
  run run_module 50-fail2ban VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  assert_output_matches '\[sshd\]'
  assert_output_matches 'bantime.maxtime   = 5w'
  refute_output_matches 'ignoreip'
}

@test "FAIL2BAN_IGNOREIP adds loopback plus the given sources to the sshd jail" {
  run run_module 50-fail2ban VMT_SHOW_CONTENT=1 'FAIL2BAN_IGNOREIP=192.168.1.10 10.0.0.0/24 fd00::/8'
  [ "$status" -eq 0 ]
  assert_output_matches 'ignoreip = 127\.0\.0\.1/8 ::1 192\.168\.1\.10 10\.0\.0\.0/24 fd00::/8'
}

@test "ignoreip sits in the sshd section, after the jail settings" {
  run run_module 50-fail2ban VMT_SHOW_CONTENT=1 FAIL2BAN_IGNOREIP=192.168.1.10
  [ "$status" -eq 0 ]
  jail="$(sed -n '/\[sshd\]/,$p' <<<"$output")"
  grep -q 'ignoreip = 127.0.0.1/8 ::1 192.168.1.10' <<<"$jail"
}

@test "a value that is not an address is rejected" {
  run run_module 50-fail2ban 'FAIL2BAN_IGNOREIP=192.168.1.10 my-laptop'
  [ "$status" -eq 1 ]
  assert_output_matches "FAIL2BAN_IGNOREIP: 'my-laptop' is not an IPv4/IPv6 address or CIDR"
}

@test "an out-of-range octet or prefix is rejected" {
  run run_module 50-fail2ban FAIL2BAN_IGNOREIP=192.168.1.300
  [ "$status" -eq 1 ]
  run run_module 50-fail2ban FAIL2BAN_IGNOREIP=192.168.1.0/33
  [ "$status" -eq 1 ]
}
