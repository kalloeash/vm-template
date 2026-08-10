# vm-template

Hardened Debian-family VM baseline: idempotent Bash modules run by a Makefile. Default
branch `develop`. This file is the entry point for any agent picking up work here.

## Before you touch anything

1. Read [docs/ASSESSMENT.md](docs/ASSESSMENT.md) — the why behind every module and every
   deliberate omission.
2. Read [docs/STYLE.md](docs/STYLE.md) — **hard rules**: no AI attribution anywhere
   (commits, docs, comments), no AI-tell vocabulary. `scripts/lint-language.sh` enforces
   it in pre-commit and on `commit-msg`; a violation blocks the commit.
3. Pick a ticket from [tickets/README.md](tickets/README.md) with status `ready`. Do the
   whole ticket, nothing outside its scope.

## Working rules

- One ticket = one branch = one PR. Conventional Commits (enforced by
  conventional-pre-commit). No AI co-author trailers — see STYLE.md.
- Every module is idempotent, sources `lib/common.sh`, honors `DRY_RUN=1`, and prints
  `CHANGED:`/`OK:` per step. A second `make harden` printing all `OK` is the idempotence
  proof.
- Verification is separate from mutation: `make audit` must never change the system.

## After every change

```bash
make lint                      # shellcheck + shfmt
pre-commit run --all-files     # style, secrets, conventional-commit, language rule
bats tests/                    # once ticket 010 lands
```

Do not mark a ticket done unless its acceptance criteria pass and the checkboxes in its
Definition of done are all ticked. Tier-3 (real VM) criteria may be deferred to a
maintainer with a note — never silently skipped.

## Baseline

Base modules (00–90) implemented and verified on a real Ubuntu 24.04 VM as of
2026-08-09: all state checks pass, `ssh-audit` clean, idempotent, Lynis hardening index
78 (see [docs/lynis-baseline.md](docs/lynis-baseline.md)). arm64 paths validated in QEMU;
physical Raspberry Pi acceptance still pending. Open: bats unit suite (010), CI (011),
cloud-init end-to-end (013), SSH host-key hygiene (015).
A PR must not drop the Lynis index below the recorded baseline.

Claims in the docs must describe what the code does today. When a spec line describes
work that is not implemented, either implement it or move it to a ticket and say so —
do not leave the two out of step.
