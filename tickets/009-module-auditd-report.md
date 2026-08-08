# 009 — `80-auditd` + `90-report`

**Status:** ready
**Depends on:** 001–008

## Context

Optional audit trail (assessment §2.4) plus the verification module that gives the run an
independent grade (Lynis index, ssh-audit, Trivy).

## Scope

**In:**
- `80-auditd` (only under `TIER=full`): install auditd + a minimal ruleset (identity
  files, sshd_config, docker daemon config, privileged execs). Base tier always sets
  journald `Storage=persistent`.
- `90-report`: per-module `CHANGED/OK` table, `lynis audit system --quick` hardening
  index, `ssh-audit localhost` summary, `trivy image` on any running encryptedlink images,
  and the reboot-required flag. `AUDIT_ONLY=1` runs report without any mutation (this is
  `make audit`).

**Out:**
- AIDE (separate optional ticket if wanted).

## Acceptance criteria

1. `make audit` changes nothing (assert: no `CHANGED:` lines; git-clean on a repo-tracked
   test fixture).
2. Report prints a numeric Lynis hardening index (target ≥ 75 on a real host; fresh images
   are ~50–65) plus the count of open Lynis warnings, and a non-empty ssh-audit summary.
   Warnings are surfaced, not just the score.
3. Under `TIER=full`, `auditctl -l` lists the shipped rules; base tier leaves auditd
   absent but journald persistent.
4. Trivy step is skipped with a note when no target images are present (not a failure).

## Test plan

- **Tier 2 (WSL):** report renders; Lynis runs (index number may differ from a real host).
- **Tier 3 (Hetzner):** full `make harden TIER=full` then `make audit`; record the Lynis
  index into `docs/lynis-baseline.md`.

## Definition of done

- [ ] Acceptance criteria pass · `make lint` clean · `AUDIT_ONLY=1` truly read-only
      · STYLE.md clean
