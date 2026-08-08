# 006 — `50-fail2ban`: sshd jail

**Status:** ready
**Depends on:** 001, 004

## Context

Port the encryptedlinkvm fail2ban jail (already good — incremental bans to 5w) and fix
the `jail.conf → jail.local` full-copy anti-pattern noted in assessment §3.2.

## Scope

**In:**
- Install fail2ban; deploy only `jail.d/sshd.local` (maxretry 3, findtime 600,
  bantime 3600, `bantime.increment`, factor 24, maxtime 5w, systemd backend).
- Enable + start the service.

**Out:**
- Web/app jails (application concern, not host baseline).
- CrowdSec (separate evaluation, ticket 012).

## Acceptance criteria

1. `fail2ban-client status sshd` succeeds and shows the jail active.
2. No `/etc/fail2ban/jail.local` full copy is created (only `jail.d/sshd.local`).
3. Config values match the spec (`fail2ban-client get sshd maxretry` = 3, bantime 3600).
4. Idempotent; re-running does not restart the service when config is unchanged.

## Test plan

- **Tier 2 (WSL):** systemd present → install + assert config values and service state.
- **Tier 3 (Hetzner):** trigger 3 failed logins from a second host, confirm the source IP
  is banned, then unban.

## Definition of done

- [ ] Acceptance criteria pass · `make lint` clean · idempotent · `DRY_RUN=1` · STYLE.md clean
