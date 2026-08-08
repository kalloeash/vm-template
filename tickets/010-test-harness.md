# 010 — bats-core suite + WSL + Hetzner acceptance harness

**Status:** ready
**Depends on:** 001

## Context

[TESTING.md](../docs/TESTING.md) defines three tiers; this ticket builds the harness so
every module ticket can state "runs green" as a checkable fact.

## Scope

**In:**
- `tests/` bats-core suite: per-module assertion tests (file state, `sshd -T`, apt policy,
  idempotence "second run all-OK").
- `scripts/test-wsl.ps1`: import a clean rootfs, run `make harden` + bats, unregister.
- `scripts/test-hetzner.sh`: `hcloud` create → run → `make audit` → lockout drill →
  delete, with a trap so a failed run still deletes the VM.
- `docs/lynis-baseline.md` seeded with the first recorded index per distro.

**Out:**
- CI wiring (ticket 011).

## Acceptance criteria

1. `bats tests/` runs locally against the WSL tier and reports per-module results.
2. `test-hetzner.sh` always deletes its VM, including on failure (trap verified).
3. The idempotence assertion fails loudly if any module prints `CHANGED:` on a second run.
4. Lockout drill asserts: key admin in, password refused, root refused, `sudo` works.

## Test plan

Self-testing by nature; validate the harness against the finished module 001 first.

## Definition of done

- [ ] Harness runs on all `ready` modules · `make lint` clean · STYLE.md clean
- [ ] `hcloud` teardown proven on an intentionally-failing run
