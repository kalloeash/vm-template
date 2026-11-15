#!/usr/bin/env bats
# 10-update — the optional knobs for devices that update unattended: skipping the
# immediate dist-upgrade, holding packages back, and the Raspberry Pi archive origin.
# See tickets/016 and docs/RASPBERRY-PI.md.

setup() {
  load helpers/common
  require_userns
  setup_stubs
  SRC="$BATS_TEST_TMPDIR/apt-sources"
  mkdir -p "$SRC"
  # apt-cache that knows no Raspberry Pi archive unless a test says otherwise
  cat >"$STUB_BIN/apt-cache" <<'SH'
#!/bin/bash
echo ' 500 http://archive.ubuntu.com/ubuntu noble/main arm64 Packages'
SH
  chmod +x "$STUB_BIN/apt-cache"
}

rpi_policy() {
  cat >"$STUB_BIN/apt-cache" <<'SH'
#!/bin/bash
cat <<'POLICY'
 500 http://archive.raspberrypi.com/debian trixie/main arm64 Packages
     release o=Raspberry Pi Foundation,a=stable,n=trixie,l=Raspberry Pi Foundation,c=main,b=arm64
POLICY
SH
  chmod +x "$STUB_BIN/apt-cache"
}

# --- UPDATE_SKIP_DIST_UPGRADE -------------------------------------------------

@test "the dist-upgrade runs by default" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC"
  [ "$status" -eq 0 ]
  assert_output_matches 'apt update \+ dist-upgrade'
  refute_output_matches 'dist-upgrade skipped'
}

@test "UPDATE_SKIP_DIST_UPGRADE=1 skips the dist-upgrade and keeps the policy" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" UPDATE_SKIP_DIST_UPGRADE=1
  [ "$status" -eq 0 ]
  assert_output_matches 'dist-upgrade skipped \(UPDATE_SKIP_DIST_UPGRADE=1\)'
  refute_output_matches 'apt update \+ dist-upgrade'
  assert_output_matches '52-vmt-autoupgrade'
}

@test "UPDATE_SKIP_DIST_UPGRADE=0 behaves like the default" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" UPDATE_SKIP_DIST_UPGRADE=0
  [ "$status" -eq 0 ]
  assert_output_matches 'apt update \+ dist-upgrade'
}

@test "an invalid UPDATE_SKIP_DIST_UPGRADE is rejected" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" UPDATE_SKIP_DIST_UPGRADE=yes
  [ "$status" -eq 1 ]
  assert_output_matches 'UPDATE_SKIP_DIST_UPGRADE must be 0 or 1'
}

# --- UPGRADE_HOLD_PACKAGES ----------------------------------------------------

@test "no blacklist is written when UPGRADE_HOLD_PACKAGES is empty" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  refute_output_matches 'Package-Blacklist'
}

@test "UPGRADE_HOLD_PACKAGES renders one anchored regex per pattern" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" VMT_SHOW_CONTENT=1 \
    'UPGRADE_HOLD_PACKAGES=linux-image-* raspi-firmware rpi-eeprom libc6 g++-?'
  [ "$status" -eq 0 ]
  assert_output_matches 'Unattended-Upgrade::Package-Blacklist \{'
  assert_output_matches '"linux-image-.*\$";'
  assert_output_matches '"raspi-firmware\$";'
  assert_output_matches '"rpi-eeprom\$";'
  assert_output_matches '"libc6\$";'
  # '+' is escaped as a character class, '?' becomes a single-character wildcard
  assert_output_matches '"g\[\+\]\[\+\]-\.\$";'
}

@test "a dot in a pattern matches only a dot" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" VMT_SHOW_CONTENT=1 'UPGRADE_HOLD_PACKAGES=libfoo1.2'
  [ "$status" -eq 0 ]
  assert_output_matches '"libfoo1\[\.\]2\$";'
}

@test "a pattern that is not a package name is rejected" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" 'UPGRADE_HOLD_PACKAGES=linux-*;rm'
  [ "$status" -eq 1 ]
  assert_output_matches "UPGRADE_HOLD_PACKAGES: 'linux-\*;rm' is not a package name pattern"
}

# --- Raspberry Pi archive origin ----------------------------------------------

@test "no Raspberry Pi drop-in when the archive is not configured" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  assert_output_matches 'Raspberry Pi archive not configured'
  refute_output_matches '53-vmt-raspberrypi-origin'
  refute_output_matches 'Raspberry Pi Foundation'
}

@test "the drop-in is written when apt policy shows the Raspberry Pi archive" {
  rpi_policy
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  assert_output_matches '53-vmt-raspberrypi-origin'
  assert_output_matches 'Origins-Pattern:: "origin=Raspberry Pi Foundation,codename=\$\{distro_codename\},label=Raspberry Pi Foundation";'
}

@test "the drop-in is written when only the apt sources name the archive (deb822)" {
  cat >"$SRC/raspi.sources" <<'SRC'
Types: deb
URIs: http://archive.raspberrypi.com/debian/
Suites: trixie
Components: main
SRC
  run run_module 10-update "APT_SOURCE_PATHS=$SRC"
  [ "$status" -eq 0 ]
  assert_output_matches '53-vmt-raspberrypi-origin'
}

@test "the drop-in is written when only the apt sources name the archive (one-line)" {
  echo 'deb http://archive.raspberrypi.com/debian/ trixie main' >"$SRC/raspi.list"
  run run_module 10-update "APT_SOURCE_PATHS=$SRC"
  [ "$status" -eq 0 ]
  assert_output_matches '53-vmt-raspberrypi-origin'
}

@test "a commented-out archive line does not count" {
  echo '#deb http://archive.raspberrypi.com/debian/ trixie main' >"$SRC/raspi.list"
  run run_module 10-update "APT_SOURCE_PATHS=$SRC"
  [ "$status" -eq 0 ]
  refute_output_matches '53-vmt-raspberrypi-origin'
}

@test "the Raspberry Pi origin never lands in the main policy file" {
  rpi_policy
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  # the policy file's content is printed before the drop-in's header line
  policy_part="$(sed -n '/52-vmt-autoupgrade/,/53-vmt-raspberrypi-origin/p' <<<"$output")"
  [ -n "$policy_part" ]
  if grep -q 'Raspberry' <<<"$policy_part"; then return 1; fi
}

# --- unattended-upgrades syntax and kernel removal ---------------------------------

# /etc/os-release fixtures, so the Debian and Kali branches run on any runner.
os_release() { # os_release ID CODENAME
  printf 'ID=%s\nVERSION_CODENAME=%s\n' "$1" "$2" >"$BATS_TEST_TMPDIR/os-release"
  OSR="VMT_OS_RELEASE=$BATS_TEST_TMPDIR/os-release"
}

@test "Debian origins use Origins-Pattern, the only key that takes origin=... strings" {
  os_release debian trixie
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" "$OSR" VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  assert_output_matches 'Unattended-Upgrade::Origins-Pattern \{'
  refute_output_matches 'Allowed-Origins'
  assert_output_matches '"origin=Debian,codename=\$\{distro_codename\},label=Debian";'
}

@test "the Debian security origin matches the -security suite codename" {
  os_release debian trixie
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" "$OSR" VMT_SHOW_CONTENT=1
  assert_output_matches '"origin=Debian,codename=\$\{distro_codename\}-security,label=Debian-Security";'
  assert_output_matches '"origin=Debian,codename=\$\{distro_codename\}-updates,label=Debian";'
}

@test "Kali origins use Origins-Pattern too" {
  os_release kali kali-rolling
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" "$OSR" VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  assert_output_matches 'Unattended-Upgrade::Origins-Pattern \{'
  refute_output_matches 'Allowed-Origins'
}

@test "Ubuntu keeps the legacy Allowed-Origins form" {
  os_release ubuntu noble
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" "$OSR" VMT_SHOW_CONTENT=1
  [ "$status" -eq 0 ]
  assert_output_matches 'Unattended-Upgrade::Allowed-Origins \{'
  assert_output_matches '"\$\{distro_id\}:\$\{distro_codename\}-security";'
  refute_output_matches 'Origins-Pattern \{'
}

@test "old kernels are removed by default" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" VMT_SHOW_CONTENT=1
  assert_output_matches 'Remove-Unused-Kernel-Packages "true";'
}

@test "UPGRADE_REMOVE_UNUSED_KERNELS=0 keeps the previous kernel" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" VMT_SHOW_CONTENT=1 UPGRADE_REMOVE_UNUSED_KERNELS=0
  [ "$status" -eq 0 ]
  assert_output_matches 'Remove-Unused-Kernel-Packages "false";'
}

@test "an invalid UPGRADE_REMOVE_UNUSED_KERNELS is rejected" {
  run run_module 10-update "APT_SOURCE_PATHS=$SRC" UPGRADE_REMOVE_UNUSED_KERNELS=no
  [ "$status" -eq 1 ]
  assert_output_matches 'UPGRADE_REMOVE_UNUSED_KERNELS must be 0 or 1'
}
