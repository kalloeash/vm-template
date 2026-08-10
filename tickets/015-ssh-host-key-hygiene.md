# 015 — `30-ssh`: host-key and moduli hygiene

**Status:** done
**Depends on:** 004

## Context

[HARDENING.md](../docs/HARDENING.md) §30-ssh once claimed the module would "regenerate
weak host keys if present (drop small-moduli, keep ed25519 + rsa-4096)". It did not. The
claim was removed and the work split out here; this ticket delivered it.

## Scope

**In:**
- Prune `/etc/ssh/moduli` of groups below `SSH_MIN_MODULUS` (default 3071 bits), written
  through a temp file and installed only when usable groups survive the filter.
- Report an RSA host key below 3072 bits; replace it at 4096 bits under
  `SSH_REGEN_HOST_KEYS=1`.
- `make audit` assertions for both, so neither can regress silently.

**Out:**
- Rotating a healthy host key. Rotation breaks every client's `known_hosts` for no
  security gain, and this baseline is applied to hosts already in service.
- Certificate-based host authentication (a separate decision, not hygiene).

## Decisions that changed during implementation

1. **Host-key replacement is opt-in, not automatic.** The original criterion said any
   RSA key under 4096 bits should be regenerated. Ubuntu and Debian ship 3072-bit keys,
   which `ssh-audit` passes; regenerating them by default would hand every existing
   client a host-key mismatch on an ordinary `make harden`. The floor is 3072 with a
   warning, and replacement happens only when asked for.
2. **ecdsa key material is not deleted.** The drop-in already stops sshd offering it, and
   `ssh-keygen -A` recreates missing host keys on the next service start, so deletion is
   not durable. Removing it would only look tidier.

## Acceptance criteria

1. After `make ssh`, `awk '!/^#/ && NF>=5 && $5 < 3071' /etc/ssh/moduli | wc -l` is `0`,
   and the file still contains at least one group. ✅ verified on ubuntu-24.04
2. `make audit` fails if a group below the floor is reintroduced. ✅
3. `ssh-audit -l warn 127.0.0.1` stays clean. ✅
4. Idempotent: a second run prints `OK` for both steps and rewrites nothing. ✅
5. A moduli file with nothing above the floor is left untouched with a warning, never
   emptied. ✅ covered by the bats suite

## Test plan

- **Tier 1/2:** the filter and the empty-result guard against fixtures (`tests/module-ssh.bats`).
- **Tier 3:** `scripts/test-hetzner.sh` — moduli floor asserted by `make audit` on a real VM.

## Definition of done

- [x] Acceptance criteria 1–5 pass
- [x] `make lint` clean (shellcheck + shfmt)
- [x] Idempotent: second run prints `OK` for every step
- [x] `DRY_RUN=1` supported
- [x] Conforms to [STYLE.md](../docs/STYLE.md)
- [x] HARDENING.md §30-ssh describes the delivered behavior
