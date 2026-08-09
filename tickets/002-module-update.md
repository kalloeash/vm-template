# 002 — `10-update`: upgrades, unattended-upgrades, needrestart

**Status:** ready
**Depends on:** 001

## Context

Generalizes the reference deployment's update step + `52autoreboot.conf`, and closes the
needrestart gap (assessment §2.5): unattended-upgrades reboots for kernel/libc but leaves
daemons running against deleted libraries after other upgrades.

## Scope

**In:**
- `apt-get update` + `dist-upgrade` keeping local config (`-o Dpkg::Options::=--force-confold`).
- Install/enable `unattended-upgrades`; deploy the `52autoreboot.conf` policy (also
  `-updates`, auto-reboot 04:00, kernel + dependency cleanup). Kali: kali-rolling origins,
  auto-reboot off by default.
- Install `needrestart`, set automatic restart mode.
- Assert time sync (`timesyncd`/`chrony`) active.

**Out:**
- Docker upgrades (manual by deliberate choice — documented in the source file).

## Acceptance criteria

1. `apt-config dump` shows `Automatic-Reboot "true"`, `Automatic-Reboot-Time "04:00"`,
   and the `-updates` allowed-origin.
2. `systemctl is-enabled unattended-upgrades` = `enabled`.
3. `needrestart` present and in automatic mode (`grep restart /etc/needrestart/needrestart.conf`).
4. `timedatectl show -p NTPSynchronized` = `yes` (skip-with-note if the test env has no NTP).
5. Idempotent; on Kali the policy uses kali-rolling origins and does not set auto-reboot.

## Test plan

- **Tier 2 (WSL):** assert apt policy + installed packages; do not trigger a real upgrade.
- **Tier 3 (Hetzner):** full run; confirm `unattended-upgrade --dry-run -d` selects the
  expected origins.

## Definition of done

- [ ] Acceptance criteria pass on Ubuntu 24.04, Debian 13, Kali (adapted)
- [ ] `make lint` clean · idempotent · `DRY_RUN=1` · STYLE.md clean
