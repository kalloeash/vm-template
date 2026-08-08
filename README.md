# vm-template

Opinionated, idempotent baseline for a fresh Debian-family VM (Ubuntu 22.04/24.04,
Debian 12/13; Kali best-effort). One `make harden` takes a stock cloud image to the
hardened state that [encryptedlinkvm](https://github.com/kalloeash/encryptedlinkvm)'s
QUICKSTART builds by hand — plus the gaps that manual process misses.

**Status: design + assessment phase** (2026-08-09). Specs and tickets are complete;
module implementations follow. Start here:

- [docs/ASSESSMENT.md](docs/ASSESSMENT.md) — gap analysis, decisions, mistakes found in
  the manual process, research sources
- [docs/HARDENING.md](docs/HARDENING.md) — per-module spec and deliberate omissions
- [docs/TOOLING.md](docs/TOOLING.md) — every tool, why it's in or out
- [docs/TESTING.md](docs/TESTING.md) — three-tier test strategy
- [docs/STYLE.md](docs/STYLE.md) — writing rules (enforced), including the no-AI-language rule
- [tickets/](tickets/) — the agent-ready build plan, one file per unit of work
- [CONTRIBUTING.md](CONTRIBUTING.md) / [CLAUDE.md](CLAUDE.md) — how to work here

## Design in one paragraph

Plain **Bash modules orchestrated by a Makefile** — no Ansible, no agent, no control
node. Each module is a standalone, idempotent script (`modules/NN-name.sh`) that can be
run alone (`make ssh`) or in sequence (`make harden`), always safe to re-run, and prints
`CHANGED`/`OK` per step so a second run proving `OK` everywhere *is* the idempotence
test. Verification is separated from mutation: `make audit` runs
[Lynis](https://cisofy.com/lynis/) + `ssh-audit` + our own assertions and touches
nothing.

## Layout

```
vm-template/
├── Makefile              # harden / audit / lint / individual modules
├── modules/
│   ├── 00-preflight.sh   # distro detect, root check, SSH-key lockout guard
│   ├── 10-update.sh      # full upgrade + unattended-upgrades + autoreboot policy
│   ├── 20-user.sh        # admin user + sudo, stop using root
│   ├── 30-ssh.sh         # keys-only, no root login, modern algos (ssh-audit clean)
│   ├── 40-firewall.sh    # ufw default-deny + Docker DOCKER-USER integration
│   ├── 50-fail2ban.sh    # sshd jail with incremental bans (from encryptedlinkvm)
│   ├── 60-sysctl.sh      # network + kernel hardening (rp_filter, syncookies, ptrace…)
│   ├── 70-docker.sh      # official repo, daemon.json (log caps, live-restore)
│   ├── 80-auditd.sh      # audit trail (optional tier)
│   └── 90-report.sh      # summary + Lynis hardening index
├── lib/common.sh         # log helpers, changed/ok tracking, os-release detection
├── scripts/lint-language.sh # STYLE.md enforcement (no AI attribution / AI-tell words)
├── tests/                   # bats-core suite (ticket 010)
├── tickets/                 # file-based backlog, one unit of work per file
├── docs/
│   ├── ASSESSMENT.md     # gap analysis, decisions, mistakes found, research sources
│   ├── HARDENING.md      # per-module rationale: what, why, what we deliberately skip
│   ├── TOOLING.md        # every tool, why it's in or out
│   ├── TESTING.md        # lint → WSL smoke → throwaway Hetzner VM acceptance
│   └── STYLE.md          # writing rules, enforced by pre-commit
├── CONTRIBUTING.md · CLAUDE.md
└── .pre-commit-config.yaml  # shellcheck, shfmt, gitleaks, conventional-commits, language
```

## Intended usage (once implemented)

```bash
# on a fresh VM, as root or sudo-capable user:
git clone <this repo> && cd vm-template
make harden                 # everything, in order, with a lockout guard
make audit                  # Lynis score + ssh-audit + assertions, changes nothing

# or piecemeal:
make ssh                    # just the SSH module
make firewall EXTRA_PORTS="80/tcp 443/tcp"
```

## Non-goals

- Fleet management (use Ansible + dev-sec/ansible-lockdown when there's more than a
  handful of hosts)
- Compliance evidence (CIS section tagging) — we take CIS Level 1 *ideas*, not the audit
  paperwork
- RHEL-family support (dnf/firewalld double every code path; out of scope until needed)

## License

Proprietary — © 2026 kalloeash. All rights reserved.
