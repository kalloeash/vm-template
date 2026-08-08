# Tickets

File-based backlog, one Markdown file per unit of work, sized so a single agent can pick
one up and finish it in one pass without cross-ticket coordination. This is the build
plan for the modules the [assessment](../docs/ASSESSMENT.md) specifies.

## Conventions

- Filename: `NNN-short-slug.md` (`NNN` = stable id, not priority).
- Every ticket follows [`_TEMPLATE.md`](_TEMPLATE.md): Context, Scope (in/out),
  Acceptance criteria, Test plan, Dependencies, Definition of done.
- Status lives in the table below, not in the file, so one glance shows the board.
- A ticket is **agent-ready** only when its acceptance criteria are verifiable without
  asking a human a question. If it isn't, it stays `draft`.

## Board

| Ticket | Title | Status | Depends on |
|---|---|---|---|
| [001](001-lib-common-and-preflight.md) | Harden `lib/common.sh` + finish preflight guard | ready | — |
| [002](002-module-update.md) | `10-update`: upgrades, unattended-upgrades, needrestart | ready | 001 |
| [003](003-module-user.md) | `20-user`: admin user + sudo | ready | 001 |
| [004](004-module-ssh.md) | `30-ssh`: keys-only, modern algorithms, lockout-safe | ready | 001, 003 |
| [005](005-module-firewall.md) | `40-firewall`: ufw + Docker DOCKER-USER integration | ready | 001 |
| [006](006-module-fail2ban.md) | `50-fail2ban`: sshd jail | ready | 001, 004 |
| [007](007-module-sysctl.md) | `60-sysctl`: network + kernel hardening | ready | 001 |
| [008](008-module-docker.md) | `70-docker`: repo install + `daemon.json` caps | ready | 001 |
| [009](009-module-auditd-report.md) | `80-auditd` + `90-report` (Lynis/ssh-audit/Trivy) | ready | 001–008 |
| [010](010-test-harness.md) | bats-core suite + WSL + Hetzner acceptance harness | ready | 001 |
| [011](011-ci-github-actions.md) | CI: pre-commit + lint-language + bats on PR | draft | 010 |
| [012](012-crowdsec-evaluation.md) | Evaluate CrowdSec vs fail2ban | draft | 006 |

Legend: `draft` = needs a decision before an agent starts · `ready` = agent-pickable ·
`in-progress` · `done`.
