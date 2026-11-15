# vm-template

Opinionated, idempotent baseline for a fresh Debian-family VM (Ubuntu 22.04/24.04,
Debian 12/13; Kali best-effort). One `make harden` takes a stock cloud image to the
hardened state a typical manual setup guide builds by hand — plus the gaps that manual
process usually misses (restricting which SSH host keys are offered, journald
persistence, Docker log caps, kernel/sysctl, and more).

**Status: implemented and verified.** Every module runs on throwaway Ubuntu 24.04 and
Debian 13 VMs: all mandatory controls pass, a second run reports no changes, `ssh-audit`
is clean, the lockout drill passes, and `make audit` exits non-zero when a control is
broken. Lynis hardening index 77–79 (see
[docs/lynis-baseline.md](docs/lynis-baseline.md)). First-boot delivery via cloud-init is
verified end to end. On **arm64** the baseline is applied for real on aarch64 hardware by
CI on every PR.

Verification: 54 unit tests (`make test`), CI running the real baseline on amd64 and
arm64, and a one-command acceptance run against a disposable VM
([`scripts/test-hetzner.sh`](scripts/test-hetzner.sh)).

Two things are **not** verified and are not claimed to be: the SSH lockout drill on
arm64 (it needs a VM reachable from outside, and ARM capacity was unavailable), and
physical Raspberry Pi hardware — which sysctl keys the `linux-raspi` kernel omits, and
the USB-root detection in `65-hardening`, can only be confirmed on a real board.

Start here:

- [docs/ASSESSMENT.md](docs/ASSESSMENT.md) — gap analysis, decisions, mistakes found in
  the manual process, research sources
- [docs/HARDENING.md](docs/HARDENING.md) — per-module spec and deliberate omissions
- [docs/TOOLING.md](docs/TOOLING.md) — every tool, why it's in or out
- [docs/DELIVERY.md](docs/DELIVERY.md) — three ways hardening reaches a box (post-boot / cloud-init / Packer)
- [docs/RASPBERRY-PI.md](docs/RASPBERRY-PI.md) — kiosk profile for Raspberry Pi OS, and what is not verified on real hardware
- [docs/TESTING.md](docs/TESTING.md) — three-tier test strategy
- [docs/STYLE.md](docs/STYLE.md) — writing rules (enforced), including the no-AI-language rule
- [tickets/](tickets/) — the agent-ready build plan, one file per unit of work
- [CHANGELOG.md](CHANGELOG.md) — what changed per release, and the known gaps
- [CONTRIBUTING.md](CONTRIBUTING.md) / [CLAUDE.md](CLAUDE.md) — how to work here

## Quick start

**Prerequisites on the target box:**
- A login that is in the **`sudo`** group and carries your SSH public key. On a fresh
  cloud image that is usually `root` or the default `ubuntu`/`admin` user. **Note for
  Raspberry Pi:** Pi Imager's Ubuntu customization creates your user but does *not* always
  add it to `sudo` — verify with `groups`, and if it's missing, add it from an
  already-privileged account: `sudo usermod -aG sudo <you>` (the default `ubuntu` user on
  the Ubuntu Pi image has sudo).
- `git` and `make` (not on a minimal image by default).

```bash
sudo apt update && sudo apt install -y git make
git clone https://github.com/kalloeash/vm-template
cd vm-template
# Pin ADMIN_USER to the account that already holds your SSH key, so hardening keeps that
# key when it disables root + password login (otherwise you can lock yourself out):
sudo make harden ADMIN_USER=$(whoami)

# The admin account is key-only by default, so sudo is configured NOPASSWD — a locked
# password plus a password prompt would leave no way to reach root. For a password-based
# admin instead (sudo then asks for it), pass the hash in the ENVIRONMENT — make expands
# `$` in command-line variables and would mangle a $6$... hash:
#   sudo ADMIN_PASSWORD_HASH="$(openssl passwd -6)" make harden ADMIN_USER=ops

# Optional: install the audit tools so `make audit` reports a Lynis index + ssh-audit
sudo apt install -y lynis ssh-audit
sudo make audit          # verify only — state checks, ssh-audit, Lynis index; changes nothing
```

`make harden` is idempotent — re-run it any time. See [docs/DELIVERY.md](docs/DELIVERY.md)
for the cloud-init and Packer paths.

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
│   ├── 50-fail2ban.sh    # sshd jail with incremental bans
│   ├── 60-sysctl.sh      # network + kernel hardening (rp_filter, syncookies, ptrace…)
│   ├── 70-docker.sh      # official repo, daemon.json (log caps, live-restore)
│   ├── 80-auditd.sh      # audit trail (optional tier)
│   └── 90-report.sh      # summary + Lynis hardening index
├── lib/common.sh         # log helpers, changed/ok tracking, os-release detection
├── scripts/
│   ├── lint-language.sh     # STYLE.md enforcement (no AI attribution / AI-tell words)
│   ├── test-hetzner.sh      # tier-3 acceptance on a disposable VM (EXTENDED=1 for more)
│   └── test-cloud-init.sh   # first-boot delivery, verified end to end
├── examples/cloud-init.yaml # delivery path B, ready to paste into user-data
├── examples/raspberry-pi-kiosk.env  # variable set for a Raspberry Pi kiosk (docs/RASPBERRY-PI.md)
├── tests/                   # bats-core suite: make test
├── .github/workflows/ci.yml # lint, pre-commit, bats, and the real baseline on amd64+arm64
├── tickets/                 # file-based backlog, one unit of work per file
├── docs/
│   ├── ASSESSMENT.md     # gap analysis, decisions, mistakes found, research sources
│   ├── HARDENING.md      # per-module rationale: what, why, what we deliberately skip
│   ├── RASPBERRY-PI.md   # kiosk profile: what it sets, what it does not cover
│   ├── TOOLING.md        # every tool, why it's in or out
│   ├── TESTING.md        # lint → WSL smoke → throwaway Hetzner VM acceptance
│   └── STYLE.md          # writing rules, enforced by pre-commit
├── CONTRIBUTING.md · CLAUDE.md · CHANGELOG.md
└── .pre-commit-config.yaml  # shellcheck, shfmt, gitleaks, conventional-commits, language
```

## Usage

```bash
# on a fresh VM, as root or a sudo-capable user:
git clone <this repo> && cd vm-template
sudo make harden            # everything, in order, with a lockout guard
sudo make audit             # Lynis score + ssh-audit + assertions, changes nothing

# or piecemeal:
sudo make ssh               # just the SSH module
sudo make firewall EXTRA_PORTS="80/tcp 443/tcp"

# workstation side:
make lint                   # shellcheck + shfmt
make test                   # bats unit suite
```

Verifying a change against a real VM (needs `hcloud` and an API token):

```bash
export HCLOUD_SSH_KEY=<key-name-in-your-project> SSH_KEY_FILE=~/.ssh/id_ed25519
EXTENDED=1 scripts/test-hetzner.sh ubuntu-24.04   # creates, hardens, drills, destroys
```

## Non-goals

- Fleet management (use Ansible + dev-sec/ansible-lockdown when there's more than a
  handful of hosts)
- Compliance evidence (CIS section tagging) — we take CIS Level 1 *ideas*, not the audit
  paperwork
- RHEL-family support (dnf/firewalld double every code path; out of scope until needed)

## License

[MIT](LICENSE) © 2026 kalloeash.
