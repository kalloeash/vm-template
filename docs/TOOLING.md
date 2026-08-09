# Tooling review

What we settled on, what we added after the first pass, and what we rejected. Each entry
says why so the decision is a record, not a habit.

## Runtime (on the VM)

| Tool | Role | Status |
|---|---|---|
| GNU Make | orchestrates modules; named targets, ordering, per-module reruns | core |
| Bash 4+ | module language | core |
| ufw | host firewall (default deny inbound) | core |
| fail2ban | SSH brute-force bans (incremental) | core |
| unattended-upgrades | automatic security/`-updates` patching + reboot policy | core |
| needrestart | restart daemons after library upgrades (the gap unattended-upgrades leaves) | **added** |
| Docker CE + compose plugin | container runtime, official apt repo | core |
| auditd | privileged-action audit trail | optional tier (`TIER=full`) |
| AIDE | file-integrity baseline | optional tier |

## Verification (independent of our own scripts)

| Tool | Role | Status |
|---|---|---|
| Lynis | distro-agnostic hardening index; the number we ratchet and regression-test | core |
| ssh-audit | validates the sshd algorithm set against current advice | core |
| Trivy | scan the running container images + Dockerfile for CVEs/misconfig | **added** — closes the gap that OWASP dependency-scan (source deps) does not cover the built image |
| ss / systemctl assertions | our own "did it actually take effect" checks in 90-report | core |

## Development (workstation + CI)

| Tool | Role | Status |
|---|---|---|
| shellcheck | shell static analysis | core |
| shfmt | shell formatter | core |
| pre-commit | hook runner (common repo pattern) | core |
| gitleaks | secret scanning | core |
| conventional-pre-commit | enforce Conventional Commits at commit time | **added** — many projects only *use* the convention; here we enforce it |
| **bats-core** | module unit/assertion tests | **added** — see below |
| hadolint | Dockerfile linting (for any images this repo ships) | **added** |
| hcloud CLI | create/destroy the throwaway acceptance VM (Tier 3) | core (test harness) |

### Test framework choice: bats-core, not ShellSpec

bats-core is bash-native with plain-bash test syntax, TAP output, and first-class GitHub
Actions support — a good fit because our modules are already bash-only. ShellSpec is more
portable (pure POSIX, BDD/Gherkin syntax) and worth reconsidering only if the modules ever
need to run under non-bash shells, which the Debian-family target rules out. Decision:
bats-core for the assertion tests that run in the WSL and Hetzner tiers.

## Delivery (how hardening reaches the box — see DELIVERY.md)

| Tool | Role | Status |
|---|---|---|
| cloud-init | run the modules at first boot, before the box is reachable | **added** (path B, ticket 013) — closes the post-boot day-0 window |
| Packer | bake a versioned hardened image; rebuild-not-patch | **roadmap** (path C, ticket 014) — parked until >1 host |

## Considered and rejected

- **Ansible / dev-sec / ansible-lockdown** — right tool for fleets; control-node + YAML
  overhead is wrong for 1–3 hosts. Module boundaries map onto dev-sec roles if we migrate.
  We accept the imperative-Bash tradeoff knowingly (assessment §8.2): strict idempotency
  plus `make audit` for drift, rather than a declarative engine.
- **OpenSCAP / USG (Ubuntu Security Guide)** — full CIS audit paperwork. We take CIS
  Level 1 ideas, not the compliance-evidence burden. Revisit if an org ever requires an
  attestation.
- **rkhunter / chkrootkit** — high false-positive noise; Lynis covers the useful subset.
- **Terraform** — the VM is created by the Hetzner console (prod) or `hcloud` one-liners
  (test). No fleet, no need for state management yet.
- **Prometheus/node_exporter** — monitoring is a separate concern from a first-boot
  baseline; a future `monitoring` module could add it behind a tier flag.

## Still open (tracked as tickets)

Whether to add **CrowdSec** as a modern alternative/complement to fail2ban (crowd-sourced
IP reputation) is a real question for an internet-facing box — captured in
[tickets/](../tickets/) rather than decided here.
