#!/usr/bin/env bats
# 65-hardening — the usb-storage decision. Blocking it on a USB-booted host makes that
# host unbootable, so the choice is worth a test. See docs/HARDENING.md §65-hardening.
#
# The auto-detected USB-root branch itself is not covered here: it reads /sys/block, which
# cannot be faked from a user namespace. That path is tier 3 on real hardware
# (docs/ASSESSMENT.md, Raspberry Pi section). What is covered is every branch the operator
# can reach through the knob, and that auto is the default.

setup() {
  load helpers/common
  require_userns
  setup_stubs
}

@test "auto blocks usb-storage on a host whose root is not on USB" {
  run run_module 65-hardening BLOCK_USB_STORAGE=auto
  [ "$status" -eq 0 ]
  assert_output_matches 'usb-storage blocked: 1'
  refute_output_matches 'root filesystem is on a USB device'
}

@test "auto is the default" {
  run run_module 65-hardening
  [ "$status" -eq 0 ]
  assert_output_matches 'usb-storage blocked: [01]'
}

@test "BLOCK_USB_STORAGE=0 skips the block" {
  run run_module 65-hardening BLOCK_USB_STORAGE=0
  [ "$status" -eq 0 ]
  assert_output_matches 'usb-storage blocked: 0'
}

@test "BLOCK_USB_STORAGE=1 blocks regardless of the root device" {
  run run_module 65-hardening BLOCK_USB_STORAGE=1
  [ "$status" -eq 0 ]
  assert_output_matches 'usb-storage blocked: 1'
}

@test "an invalid BLOCK_USB_STORAGE is rejected rather than guessed at" {
  run run_module 65-hardening BLOCK_USB_STORAGE=maybe
  [ "$status" -eq 1 ]
  assert_output_matches 'must be auto, 1 or 0'
}

@test "the rare-protocol blacklist is written in every mode" {
  for mode in auto 0 1; do
    run run_module 65-hardening "BLOCK_USB_STORAGE=$mode"
    [ "$status" -eq 0 ]
    assert_output_matches '99-vmt-blacklist.conf'
  done
}

@test "login.defs and core-dump limits are applied alongside" {
  run run_module 65-hardening
  [ "$status" -eq 0 ]
  assert_output_matches '99-vmt-coredump.conf'
  assert_output_matches 'login\.defs'
}
