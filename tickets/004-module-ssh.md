# 004 — `30-ssh`: keys-only, modern algorithms, lockout-safe

**Status:** ready
**Depends on:** 001 (common lib + preflight guard), 003 (admin user exists)

## Context

The biggest gap found in the assessment (§2.1): the encryptedlinkvm process recommends
keys but never edits `sshd_config`, so a provider image with `PasswordAuthentication yes`
stays brute-forceable. This module closes that, and it is the one module that can lock the
operator out — so the preflight guard from ticket 001 is a hard precondition.

## Scope

**In:**
- Drop-in `/etc/ssh/sshd_config.d/10-hardening.conf` (never edit the shipped main file).
- Settings from [HARDENING.md](../docs/HARDENING.md) §30-ssh: `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `PubkeyAuthentication yes`,
  `MaxAuthTries 3`, `LoginGraceTime 30`, `ClientAliveInterval 300`,
  `ClientAliveCountMax 2`, `X11Forwarding no`, `AllowAgentForwarding no`,
  `PermitEmptyPasswords no`; optional `AllowUsers ${ADMIN_USER}` when `SSH_ALLOW_USERS=1`.
- Modern `KexAlgorithms`/`Ciphers`/`MACs` that pass `ssh-audit` clean on the target
  OpenSSH version.
- `sshd -t` validation before reloading; reload (not restart) to avoid dropping the
  current session.

**Out:**
- SSH port change (rejected in assessment §7).
- MFA / hardware-token auth (future ticket if ever needed).
- Host-key regeneration beyond dropping known-weak keys.

## Acceptance criteria

1. After `make ssh`, `sshd -T | grep -E 'passwordauthentication|permitrootlogin'` prints
   `passwordauthentication no` and `permitrootlogin no`.
2. `ssh-audit -l warn localhost` exits 0 (no warn/fail findings) on Ubuntu 24.04.
3. If preflight's lockout guard did not pass, the module exits non-zero **without**
   modifying `sshd_config.d/` (assert: file absent after a guard-failed run).
4. A key-authenticated admin session survives the reload; a password login attempt is
   refused (`ssh -o PreferredAuthentications=password` → `Permission denied`).
5. Second run prints `OK` for every step; no file rewrite when content matches.

## Test plan

- **WSL (Tier 2):** run the module in a throwaway distro; assert file content and
  `sshd -T` output. Do not trust reload/listen behavior here.
- **Hetzner (Tier 3):** full lockout drill from TESTING.md — key admin in, password
  refused, root refused, `sudo` works — then a second run for idempotence.

## Definition of done

- [ ] Acceptance criteria 1–5 pass on Ubuntu 24.04 and Debian 13
- [ ] `make lint` clean · idempotent · `DRY_RUN=1` supported
- [ ] Guard interaction documented in HARDENING.md
- [ ] STYLE.md clean
