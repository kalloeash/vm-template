# 001 — Harden `lib/common.sh` + finish preflight guard

**Status:** ready
**Depends on:** —

## Context

Every module sources `lib/common.sh` and assumes `00-preflight.sh` ran. Both exist in
skeleton form; this ticket makes them the dependable foundation the other tickets build on.

## Scope

**In:**
- `lib/common.sh`: finalize `log_*`, `install_file`, `apt_install`, `require_distro`,
  `os_id`/`os_codename`; add a `run()` wrapper honoring `DRY_RUN`, and a `CHANGED`/`OK`
  counter surfaced to `90-report`.
- `00-preflight.sh`: finalize the lockout guard (writes `/run/vm-template.lockout-ok`);
  add distro/tier validation and an apt-lock wait.

**Out:**
- Any module-specific logic.

## Acceptance criteria

1. `shellcheck lib/common.sh modules/00-preflight.sh` is clean.
2. Sourcing `common.sh` twice does not error (`set -euo pipefail` safe, no redefinition
   failures).
3. On a host with no `authorized_keys`, preflight leaves the guard file absent and prints
   the warning; with a key present (or `FORCE_LOCKOUT_OK=1`) it creates the guard file.
4. `install_file` reports `OK` when content matches and `CHANGED` when it differs; honors
   `DRY_RUN=1` (writes nothing).

## Test plan

- **Tier 1:** shellcheck + `bash -n`.
- **Tier 2 (WSL):** run preflight with and without a seeded `authorized_keys`; assert
  guard-file presence and `install_file` behavior on a temp path.

## Definition of done

- [ ] Acceptance criteria 1–4 pass
- [ ] `make lint` clean · STYLE.md clean
- [ ] Helper contract documented at the top of `common.sh`
