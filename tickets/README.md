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
| [001](001-lib-common-and-preflight.md) | Harden `lib/common.sh` + finish preflight guard | done | — |
| [002](002-module-update.md) | `10-update`: upgrades, unattended-upgrades, needrestart | done | 001 |
| [003](003-module-user.md) | `20-user`: admin user + sudo | done | 001 |
| [004](004-module-ssh.md) | `30-ssh`: keys-only, modern algorithms, lockout-safe | done | 001, 003 |
| [005](005-module-firewall.md) | `40-firewall`: ufw + Docker DOCKER-USER integration | done | 001 |
| [006](006-module-fail2ban.md) | `50-fail2ban`: sshd jail | done | 001, 004 |
| [007](007-module-sysctl.md) | `60-sysctl`: network + kernel hardening | done | 001 |
| — | `65-hardening`: login.defs, core dumps, module blacklist (added for Lynis floor) | done | 001 |
| [008](008-module-docker.md) | `70-docker`: repo install + `daemon.json` caps | done | 001 |
| [009](009-module-auditd-report.md) | `80-auditd` + `90-report` (Lynis/ssh-audit) | done | 001–008 |
| [010](010-test-harness.md) | Hetzner acceptance runner + bats unit suite | done | 001 |
| [011](011-ci-github-actions.md) | CI: lint + pre-commit + bats + DRY_RUN harden on PR | done | 010 |
| [012](012-crowdsec-evaluation.md) | Evaluate CrowdSec vs fail2ban | draft | 006 |
| [013](013-cloud-init-delivery.md) | cloud-init first-boot delivery path | done | 001–009 |
| [014](014-packer-golden-image.md) | Packer golden-image roadmap | draft | 013 |
| [015](015-ssh-host-key-hygiene.md) | `30-ssh`: host-key + moduli hygiene | done | 004 |

**Tier-3 acceptance (2026-08-09):** all base modules verified on a real Ubuntu 24.04
Hetzner VM — every control green, ssh-audit clean, idempotent, lockout drill passed,
Lynis index 78 (see [docs/lynis-baseline.md](../docs/lynis-baseline.md)).

**Tier-3 re-run (2026-08-10):** the remediation series was re-verified on throwaway
Hetzner VMs — ubuntu-24.04 four times and debian-13 twice, `EXTENDED=1` on the last of
each. All green: 34/34 mandatory controls, idempotent second run, ssh-audit clean, Lynis
78 (ubuntu) / 79 (debian), lockout drill passed, plus the criteria that were previously
deferred — the audit gate exits 1 on a broken control (009.5), a drop-in sshd rejects is
rolled back off disk (004.6), both privilege models behave (003.3, 003.5), `EXTRA_PORTS`
defaults to SSH-only (005.1), and `TIER=full` loads its ruleset.

**arm64 (2026-08-10):** the baseline is applied for real on aarch64 by CI
([`.github/workflows/ci.yml`](../.github/workflows/ci.yml), `ubuntu-24.04-arm` runners) —
harden, an idempotent second run, `make audit` passing, and `make audit` failing on a
broken control. Hetzner ARM (cax11–cax41) was `resource_unavailable` in all three
locations that offer it, so the one arm64 gap left is the SSH lockout drill, which needs
a VM reachable from outside.

**Still owed:** physical Raspberry Pi acceptance, including the USB-root detection in
65-hardening, which reads `/sys/block` and cannot be exercised anywhere else.

Legend: `draft` = needs a decision before an agent starts · `ready` = agent-pickable ·
`in-progress` · `done`.
