# 015 — `30-ssh`: host-key and moduli hygiene

**Status:** ready
**Depends on:** 004

## Context

[HARDENING.md](../docs/HARDENING.md) §30-ssh claimed the module would "regenerate weak
host keys if present (drop small-moduli, keep ed25519 + rsa-4096)". It never did. What
`30-ssh` implements is narrower: the drop-in pins `HostKey` to the ed25519 and RSA keys,
so sshd stops *offering* the ecdsa (nistp256) key `ssh-audit` flags. No key material is
generated, rotated or removed, and `/etc/ssh/moduli` is untouched.

The spec text has been corrected to describe the code. This ticket is the work that text
described, split out so the claim can come back when it is true.

## Scope

**In:**
- Prune `/etc/ssh/moduli` of groups smaller than 3071 bits
  (`awk '$5 >= 3071' /etc/ssh/moduli`), written through a temp file and only when the
  result is non-empty — an empty moduli file breaks `diffie-hellman-group-exchange-*`.
- Detect an RSA host key shorter than 4096 bits and regenerate it.
- Detect and remove the unused ecdsa host key material, not just stop offering it.
- Every step behind the same transactional pattern `30-ssh` now uses: validate with
  `sshd -t`, roll back on failure, reload rather than restart.

**Out:**
- Rotating a healthy ed25519 host key. Rotation breaks every client's `known_hosts` for
  no security gain, and this baseline is applied to hosts that are already in service.
- Certificate-based host authentication (a separate decision, not hygiene).

## Acceptance criteria

1. After `make ssh`, `awk '$5 < 3071' /etc/ssh/moduli | wc -l` prints `0`, and the file
   still has at least one entry.
2. `ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub` reports 4096 bits.
3. `ssh-audit -l warn 127.0.0.1` exits 0 on Ubuntu 24.04 and Debian 13.
4. Idempotent: a second run prints `OK` for every step and rewrites nothing.
5. Regenerating a host key emits a `WARN:` naming the fingerprint change, because every
   client that has connected before will see a host-key mismatch.

## Test plan

- **Tier 2 (WSL):** moduli pruning and the "already pruned" path against fixture files;
  assert the temp-file write and the non-empty guard.
- **Tier 3 (Hetzner):** full `make harden`, then `ssh-audit` clean, then a second run for
  idempotence. Confirm a client reconnect after any key regeneration.

## Definition of done

- [ ] Acceptance criteria 1–5 pass
- [ ] `make lint` clean (shellcheck + shfmt)
- [ ] Idempotent: second run prints `OK` for every step
- [ ] `DRY_RUN=1` supported
- [ ] Conforms to [STYLE.md](../docs/STYLE.md)
- [ ] HARDENING.md §30-ssh host-key bullet updated to describe the delivered behavior
