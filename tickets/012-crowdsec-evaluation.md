# 012 — Evaluate CrowdSec vs fail2ban

**Status:** draft
**Depends on:** 006

## Context

fail2ban bans on local log patterns only. CrowdSec adds crowd-sourced IP reputation and a
richer scenario engine — potentially worthwhile on an internet-facing box, at the cost of
a heavier agent and an external reputation dependency. This is a decision ticket, not an
implementation ticket.

## Deliverable

A short recommendation appended to [TOOLING.md](../docs/TOOLING.md): keep fail2ban, add
CrowdSec, or offer CrowdSec as an opt-in tier. Must cover: resource footprint on a CX22,
the offline/air-gapped story, false-positive handling, and whether the two can coexist
(they can, on different chains) or should not.

## Acceptance criteria

1. Recommendation recorded in TOOLING.md with reasoning and a decision.
2. If "opt-in tier", a follow-up implementation ticket is filed with scope.

## Definition of done

- [ ] Decision documented · STYLE.md clean
