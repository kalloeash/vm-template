# 013 — cloud-init first-boot delivery path

**Status:** ready
**Depends on:** 001–009 (the modules it invokes)

## Context

Assessment §8.1: applying hardening post-boot leaves a day-0 exposure window. cloud-init
runs the same modules at first boot, before the machine is reachable for its real purpose,
and can disable password SSH immediately ([DELIVERY.md](../docs/DELIVERY.md) path B). This
is the recommended path for a new single VPS.

## Scope

**In:**
- Finalize [examples/cloud-init.yaml](../examples/cloud-init.yaml): inject admin key, set
  `ssh_pwauth: false`, clone the repo, run `make harden FORCE_LOCKOUT_OK=1` (safe because
  cloud-init already provisioned the key).
- Modules must run non-interactively with no TTY: audit each for prompts, `read`, or
  assumptions of an attached terminal; fix any found.
- Document provider specifics (Hetzner user-data field) in DELIVERY.md.

**Out:**
- Packer (ticket 014).
- Baking secrets into user-data (forbidden — metadata service exposure).

## Acceptance criteria

1. A Hetzner VM created with the example user-data reaches the full hardened state with no
   SSH/console interaction, and `make audit` passes (Lynis ≥ 75).
2. Password SSH is refused from first boot (cloud-init `ssh_pwauth: false` verified before
   the modules even run).
3. Every module runs clean with no controlling TTY (`setsid`/`</dev/null` smoke test).
4. cloud-init `runcmd` exits 0; `cloud-init status --wait` reports `done`.

## Test plan

- **Tier 3 (Hetzner):** create with user-data, `cloud-init status --wait`, then the
  standard audit + lockout drill. This is the primary test — cloud-init can't be
  faithfully exercised in WSL.

## Definition of done

- [ ] Acceptance criteria pass · no-TTY safe · STYLE.md clean
- [ ] DELIVERY.md path B verified end-to-end and marked tested
