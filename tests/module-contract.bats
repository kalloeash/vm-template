#!/usr/bin/env bats
# The contract every module is supposed to keep (docs/HARDENING.md, CLAUDE.md).
# Cheap, and it catches a new module that quietly skips one of the rules.

setup() {
  load helpers/common
  MODULES=("$REPO_ROOT"/modules/*.sh)
}

@test "every module parses" {
  for m in "${MODULES[@]}"; do
    run bash -n "$m"
    [ "$status" -eq 0 ] || {
      echo "bash -n failed for $m: $output" >&2
      return 1
    }
  done
}

@test "every module has a bash shebang" {
  for m in "${MODULES[@]}"; do
    run head -1 "$m"
    [ "$output" = '#!/usr/bin/env bash' ] || {
      echo "$m starts with: $output" >&2
      return 1
    }
  done
}

@test "every module sources lib/common.sh" {
  for m in "${MODULES[@]}"; do
    grep -q 'source .*lib/common.sh' "$m" || {
      echo "$m does not source lib/common.sh" >&2
      return 1
    }
  done
}

@test "every module documents itself and points at the spec" {
  for m in "${MODULES[@]}"; do
    grep -qE '^# [0-9]{2}-[a-z0-9]+ —' "$m" || {
      echo "$m has no '# NN-name —' header line" >&2
      return 1
    }
    grep -q 'docs/HARDENING.md' "$m" || {
      echo "$m does not reference docs/HARDENING.md" >&2
      return 1
    }
  done
}

@test "every mutating module is listed in the Makefile" {
  for m in "${MODULES[@]}"; do
    local name
    name="$(basename "$m" .sh)"
    # 00-preflight and 90-report have their own targets
    case "$name" in 00-preflight | 90-report) continue ;; esac
    grep -q "$name" "$REPO_ROOT/Makefile" || {
      echo "$name is not referenced in the Makefile" >&2
      return 1
    }
  done
}

@test "only the two modules with no drop-in mechanism edit a config in place" {
  # Modules deploy drop-ins; editing a vendor file in place is the anti-pattern the
  # assessment calls out (jail.conf -> jail.local). /etc/login.defs (65-hardening) and
  # journald.conf (80-auditd) have no drop-in mechanism, so they are the exceptions.
  # A new `sed -i` anywhere else should have to justify itself in review.
  run grep -rln 'sed -i' "$REPO_ROOT/modules/"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$(basename "$file")" in
      65-hardening.sh | 80-auditd.sh) continue ;;
      *) echo "unexpected in-place config edit in $file" >&2 && return 1 ;;
    esac
  done <<<"$output"
}

@test "no module copies a whole vendor config as an override" {
  run grep -rnE 'cp .*/(jail|sshd_config|daemon)\.conf' "$REPO_ROOT/modules/"
  [ -z "$output" ] || {
    echo "wholesale vendor config copy: $output" >&2
    return 1
  }
}

@test "the audit module never mutates: no install_file or systemctl start/restart" {
  run grep -nE 'install_file|systemctl (start|restart|enable)' "$REPO_ROOT/modules/90-report.sh"
  [ -z "$output" ] || {
    echo "90-report contains a mutating call: $output" >&2
    return 1
  }
}
