#!/usr/bin/env bats
# lib/common.sh — the helpers every module builds on. See tickets/010.

setup() {
  load helpers/common
  DST="$BATS_TEST_TMPDIR/target.conf"
  SRC="$BATS_TEST_TMPDIR/source.conf"
  printf 'hello\n' >"$SRC"
  setup_stubs
}

# --- install_file -------------------------------------------------------------

@test "install_file writes a missing file and reports CHANGED" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; install_file '$DST' '$SRC'; echo flag=\$VMT_FILE_CHANGED"
  [ "$status" -eq 0 ]
  assert_output_matches "^CHANGED: $DST\$"
  assert_output_matches '^flag=1$'
  [ "$(cat "$DST")" = hello ]
}

@test "install_file leaves matching content alone and reports OK" {
  cp "$SRC" "$DST"
  run bash -c "source '$REPO_ROOT/lib/common.sh'; install_file '$DST' '$SRC'; echo flag=\$VMT_FILE_CHANGED"
  [ "$status" -eq 0 ]
  assert_output_matches "^OK: +$DST unchanged\$"
  assert_output_matches '^flag=0$'
}

@test "install_file under DRY_RUN reports the change without writing" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; DRY_RUN=1 install_file '$DST' '$SRC'; echo flag=\$VMT_FILE_CHANGED"
  [ "$status" -eq 0 ]
  assert_output_matches 'dry-run, not written'
  assert_output_matches '^flag=1$'
  [ ! -e "$DST" ]
}

@test "install_file applies the requested mode" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; install_file '$DST' '$SRC' 0440"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$DST")" = 440 ]
}

@test "VMT_FILE_CHANGED reflects the most recent call, not an earlier one" {
  run bash -c "
    source '$REPO_ROOT/lib/common.sh'
    install_file '$DST' '$SRC' >/dev/null      # writes  -> 1
    install_file '$DST' '$SRC' >/dev/null      # matches -> 0
    echo flag=\$VMT_FILE_CHANGED"
  [ "$status" -eq 0 ]
  assert_output_matches '^flag=0$'
}

# --- ensure_service_enabled ---------------------------------------------------

@test "ensure_service_enabled reports OK when the unit is already enabled and running" {
  stub_recording systemctl 0
  run_with_stubs "source '$REPO_ROOT/lib/common.sh'; ensure_service_enabled nginx"
  [ "$status" -eq 0 ]
  assert_output_matches '^OK: +nginx enabled and running$'
  refute_output_matches '^CHANGED:'
  # is-enabled + is-active only; no enable was attempted
  run stub_calls systemctl
  refute_output_matches 'enable --now'
}

@test "ensure_service_enabled enables a unit that is not running" {
  stub_dispatch systemctl 'is-enabled | is-active' 1
  run_with_stubs "source '$REPO_ROOT/lib/common.sh'; ensure_service_enabled nginx"
  [ "$status" -eq 0 ]
  assert_output_matches '^CHANGED: enabled nginx$'
  run stub_calls systemctl
  assert_output_matches 'enable --now nginx'
}

@test "ensure_service_enabled warns instead of failing when enable does not work" {
  stub_recording systemctl 1
  run_with_stubs "source '$REPO_ROOT/lib/common.sh'; ensure_service_enabled nginx 2>&1"
  [ "$status" -eq 0 ]
  assert_output_matches '^WARN: +could not enable nginx$'
}

@test "ensure_service_enabled does not touch a unit under DRY_RUN" {
  stub_dispatch systemctl 'is-enabled | is-active' 1
  run_with_stubs "source '$REPO_ROOT/lib/common.sh'; DRY_RUN=1 ensure_service_enabled nginx"
  [ "$status" -eq 0 ]
  assert_output_matches 'would enable --now nginx'
  run stub_calls systemctl
  refute_output_matches 'enable --now'
}

# --- guards and counters ------------------------------------------------------

@test "require_distro accepts a supported id and dies on an unsupported one" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; os_id=ubuntu; require_distro ubuntu debian; echo reached"
  [ "$status" -eq 0 ]
  assert_output_matches '^reached$'

  run bash -c "source '$REPO_ROOT/lib/common.sh'; os_id=fedora; require_distro ubuntu debian; echo reached" 2>&1
  [ "$status" -eq 1 ]
  refute_output_matches '^reached$'
}

@test "die exits non-zero and prints to stderr" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; die 'boom' 2>&1; echo reached"
  [ "$status" -eq 1 ]
  assert_output_matches 'FATAL: +boom'
  refute_output_matches '^reached$'
}

@test "log helpers count what they print" {
  run bash -c "
    source '$REPO_ROOT/lib/common.sh'
    log_ok a >/dev/null; log_ok b >/dev/null; log_changed c >/dev/null
    echo \"ok=\$VMT_OK changed=\$VMT_CHANGED\""
  assert_output_matches '^ok=2 changed=1$'
}

@test "run executes the command normally and only echoes it under DRY_RUN" {
  marker="$BATS_TEST_TMPDIR/marker"
  run bash -c "source '$REPO_ROOT/lib/common.sh'; run 'touch marker' touch '$marker'"
  [ "$status" -eq 0 ]
  [ -e "$marker" ]

  rm -f "$marker"
  run bash -c "source '$REPO_ROOT/lib/common.sh'; DRY_RUN=1 run 'touch marker' touch '$marker'"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  assert_output_matches 'dry-run'
}

# --- validators for the optional knobs ------------------------------------------------

@test "is_ip_or_cidr accepts IPv4, IPv6 and CIDR forms" {
  for a in 192.168.1.10 10.0.0.0/8 0.0.0.0/0 ::1 fd00::/8 2001:db8::1 fe80::1/64; do
    run bash -c "source '$REPO_ROOT/lib/common.sh'; is_ip_or_cidr '$a'"
    [ "$status" -eq 0 ] || {
      echo "rejected $a" >&2
      return 1
    }
  done
}

@test "is_ip_or_cidr rejects hostnames, bad octets and bad prefixes" {
  for a in laptop.local 192.168.1 192.168.1.256 1.2.3.4/33 fd00::/129 1.2.3.4/ abc; do
    run bash -c "source '$REPO_ROOT/lib/common.sh'; is_ip_or_cidr '$a'"
    [ "$status" -ne 0 ] || {
      echo "accepted $a" >&2
      return 1
    }
  done
}

@test "glob_to_regex anchors the end and keeps the start for re.match" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; glob_to_regex 'raspi-firmware linux-image-*'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'raspi-firmware$' ]
  [ "${lines[1]}" = 'linux-image-.*$' ]
}

@test "glob_to_regex on an empty list prints nothing" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; glob_to_regex ''"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "install_file shows the content under DRY_RUN=1 only when asked" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; DRY_RUN=1; echo hello | install_file '$BATS_TEST_TMPDIR/x' -"
  [ "$status" -eq 0 ]
  if grep -q hello <<<"$output"; then return 1; fi
  run bash -c "source '$REPO_ROOT/lib/common.sh'; DRY_RUN=1 VMT_SHOW_CONTENT=1; echo hello | install_file '$BATS_TEST_TMPDIR/x' -"
  [ "$status" -eq 0 ]
  grep -q '| hello' <<<"$output"
}
