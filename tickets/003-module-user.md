# 003 — `20-user`: admin user + sudo

**Status:** ready
**Depends on:** 001

## Context

The current process operates entirely as `root@` (assessment §2.2). This module creates a
non-root admin so root SSH can be disabled by ticket 004.

## Scope

**In:**
- Create `ADMIN_USER` (default `admin`; reuse existing `kali` on Kali), add to `sudo`.
- Copy `root`'s `authorized_keys` to the admin user if the admin has none; correct
  ownership/permissions (`700` dir, `600` file).
- Keys-only by default (locked password), with `NOPASSWD` sudo so the account is
  actually usable. `ADMIN_PASSWORD_HASH` selects the password-based model instead.

**Out:**
- Disabling root login (that is ticket 004, after keys are proven).

## Acceptance criteria

1. `id "$ADMIN_USER"` shows membership in `sudo`.
2. `/home/$ADMIN_USER/.ssh/authorized_keys` exists with mode `600`, owner `$ADMIN_USER`,
   and contains at least one key when root had one.
3. The account can reach root: either no usable password (`passwd -S` shows `L`/`NP`)
   plus a `NOPASSWD` sudoers drop-in, or a usable password (`P`) and no drop-in.
4. Idempotent: re-running neither duplicates keys nor errors on the existing user.
5. `SUDO_NOPASSWD=0` on a password-less account exits non-zero instead of producing a
   host where the admin cannot escalate.

## Test plan

- **Tier 2 (WSL):** create user, seed a fake root key, assert copy + perms + group.
- **Tier 3 (Hetzner):** confirm the admin can `sudo` before ticket 004 disables root.

## Definition of done

- [ ] Acceptance criteria pass · `make lint` clean · idempotent · `DRY_RUN=1` · STYLE.md clean
