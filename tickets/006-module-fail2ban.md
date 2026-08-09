# 006 — `50-fail2ban`: sshd jail

**Status:** ready
**Depends on:** 001, 004

## Context

Port the reference deployment's fail2ban jail (already good — incremental bans to 5w) and fix
the `jail.conf → jail.local` full-copy anti-pattern noted in assessment §3.2.

## Scope

**In:**
- Install fail2ban; deploy only `jail.d/sshd.local` (maxretry 3, findtime 600,
  bantime 3600, `bantime.increment`, factor 24, maxtime 5w).
- **`backend = systemd`** — mandatory on Ubuntu 24.04/Debian 13: sshd logs to the journal,
  not `/var/log/auth.log`, so the default `auto` backend fails to start with "Have not
  found any log file for sshd jail".
- **`allowipv6 = auto`** in the jail (or `defaults-debian.conf`) — without it fail2ban
  warns and can mishandle bans on dual-stack hosts.
- Enable + start the service.

**Out:**
- Web/app jails (application concern, not host baseline).
- CrowdSec (separate evaluation, ticket 012).

## Acceptance criteria

1. `fail2ban-client status sshd` succeeds and shows the jail active (proves the systemd
   backend resolved — this is the exact step that fails with the `auto` backend on 24.04).
2. No `/etc/fail2ban/jail.local` full copy is created (only `jail.d/sshd.local`).
3. Config values match the spec (`fail2ban-client get sshd maxretry` = 3, bantime 3600);
   `fail2ban-client get sshd logtarget` confirms the systemd journal.
4. `fail2ban-client -t` (config test) is clean — no `allowipv6` warning.
5. Idempotent; re-running does not restart the service when config is unchanged.

## Test plan

- **Tier 2 (WSL):** systemd present → install + assert config values and service state.
- **Tier 3 (Hetzner):** trigger 3 failed logins from a second host, confirm the source IP
  is banned, then unban.

## Definition of done

- [ ] Acceptance criteria pass · `make lint` clean · idempotent · `DRY_RUN=1` · STYLE.md clean
