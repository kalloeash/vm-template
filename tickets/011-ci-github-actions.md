# 011 — CI: pre-commit + lint-language + bats on PR

**Status:** draft
**Depends on:** 010

## Context

Mirror the encryptedlink repos' `pr.yml` pattern so the same gates run on every PR.
Draft until the test harness (010) exists to call.

## Open question (blocks `ready`)

The Tier-3 Hetzner acceptance costs money and needs an `HCLOUD_TOKEN` secret. Decide:
run it (a) never in CI (manual only), (b) on a label, or (c) nightly on `develop`.
Until decided, CI scope is unclear.

## Scope (once the question is answered)

**In:**
- `pr.yml`: pre-commit (shellcheck, shfmt, gitleaks, conventional-commits,
  `lint-language.sh`) + `bats tests/` on the WSL-equivalent (ubuntu-latest runner).

**Out:**
- Paid Hetzner acceptance in the default PR path (unless option c chosen).

## Acceptance criteria

1. PR to `develop` runs pre-commit + bats and blocks on failure.
2. `lint-language.sh` failure blocks the PR (prove with a fixture containing a banned word).

## Definition of done

- [ ] Open question resolved and recorded here · workflow green on a test PR · STYLE.md clean
