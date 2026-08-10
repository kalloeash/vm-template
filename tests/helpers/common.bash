#!/usr/bin/env bash
# Shared bats helpers. See docs/TESTING.md — this is tier 1/2: module logic only.
#
# Modules call require_root, so they run under `unshare -r` (a user namespace where
# EUID is 0 without any real privilege). Combined with DRY_RUN=1 that means a test can
# exercise the decision logic without touching the host: every write goes through
# install_file, which does nothing under DRY_RUN.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Tests that need EUID 0 skip themselves rather than fail where user namespaces are
# unavailable (some hardened kernels, some container runtimes).
require_userns() {
  unshare -r true 2>/dev/null || skip "user namespaces unavailable (unshare -r failed)"
}

# Run a module under fake root with DRY_RUN=1 and a stub PATH.
#   run_module 30-ssh SSH_ALLOW_USERS=1
run_module() {
  local module="$1"
  shift
  local env_assignments=("$@")
  unshare -r env PATH="$STUB_BIN:$PATH" DRY_RUN=1 "${env_assignments[@]}" \
    bash "$REPO_ROOT/modules/${module}.sh"
}

# Create a stub bin dir. Anything the modules shell out to that would otherwise reach
# the real host — or make a test depend on whether the runner has Docker — is stubbed.
setup_stubs() {
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  export STUB_BIN
  mkdir -p "$STUB_BIN"

  # Absent by default: `command -v docker` fails, so the runtime publish scan is skipped.
  stub_missing docker
  # ufw/dpkg are only consulted under DRY_RUN, but stub them so a runner that happens to
  # have them installed does not change the outcome.
  stub_missing ufw
  cat >"$STUB_BIN/dpkg" <<'SH'
#!/bin/bash
# every package looks absent, so apt_install reports "would install" under DRY_RUN
exit 1
SH
  chmod +x "$STUB_BIN/dpkg"
}

# Run shell code with the stub dir prepended to the real PATH. Prepending matters:
# an assignment that drops the rest of PATH leaves the stubs unable to find bash.
run_with_stubs() {
  run env PATH="$STUB_BIN:$PATH" bash -c "$1"
}

# A stub that behaves as if the command is not installed. `command -v` still finds it,
# so use this only where the module checks the exit status, and remove_stub where it
# checks presence.
stub_missing() {
  cat >"$STUB_BIN/$1" <<'SH'
#!/bin/bash
exit 127
SH
  chmod +x "$STUB_BIN/$1"
}

# Record every invocation to $STUB_BIN/<name>.calls and exit with $2 (default 0).
stub_recording() {
  local name="$1" rc="${2:-0}"
  cat >"$STUB_BIN/$name" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$STUB_BIN/$name.calls"
exit $rc
SH
  chmod +x "$STUB_BIN/$name"
}

# A stub whose exit status depends on the first argument:
#   stub_dispatch systemctl "is-enabled|is-active" 1
# returns 1 for the listed subcommands and 0 for everything else.
stub_dispatch() {
  local name="$1" pattern="$2" rc="${3:-1}"
  cat >"$STUB_BIN/$name" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$STUB_BIN/$name.calls"
case "\$1" in
  $pattern) exit $rc ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$STUB_BIN/$name"
}

stub_calls() { cat "$STUB_BIN/$1.calls" 2>/dev/null || true; }

# $output and $status are set by bats' `run`, not by this file (SC2154 off).
# shellcheck disable=SC2154
#
# assert_output_matches <regex> — matches against the output of the last `run`.
assert_output_matches() {
  if ! grep -qE "$1" <<<"$output"; then
    printf 'expected output to match: %s\n--- actual ---\n%s\n' "$1" "$output" >&2
    return 1
  fi
}

refute_output_matches() {
  if grep -qE "$1" <<<"$output"; then
    printf 'expected output NOT to match: %s\n--- actual ---\n%s\n' "$1" "$output" >&2
    return 1
  fi
}
