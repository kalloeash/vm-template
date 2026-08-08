# NNN — <title>

**Status:** draft | ready | in-progress | done
**Depends on:** <ticket ids, or —>

## Context

Why this exists. Link the relevant [assessment](../docs/ASSESSMENT.md) /
[spec](../docs/HARDENING.md) section. Two or three sentences.

## Scope

**In:**
- <what this ticket delivers>

**Out:**
- <explicitly not this ticket — prevents scope drift>

## Acceptance criteria

Numbered, each independently checkable (a command + expected result where possible). An
agent must be able to self-verify every item without asking a question.

1.

## Test plan

Which tier(s) from [TESTING.md](../docs/TESTING.md) apply and the exact commands.

## Definition of done

- [ ] Acceptance criteria pass
- [ ] `make lint` clean (shellcheck + shfmt)
- [ ] Idempotent: second run prints `OK` for every step
- [ ] `DRY_RUN=1` supported
- [ ] Conforms to [STYLE.md](../docs/STYLE.md) (no AI attribution / AI-tell words)
- [ ] Module rationale added to [HARDENING.md](../docs/HARDENING.md) if behavior changed
