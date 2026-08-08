# 014 — Packer golden-image roadmap

**Status:** draft
**Depends on:** 013

## Context

The mature endgame from [DELIVERY.md](../docs/DELIVERY.md) path C: bake the hardened state
into a versioned image so instances launch already compliant, drift is removed (rebuild,
don't patch), and each image carries an auditable version stamp. Overkill for one VPS —
this ticket stays `draft` until there is a second instance or a compliance requirement.

## Open question (blocks `ready`)

Is there a second host or an audit-trail requirement yet? If no, this stays parked — do
not build a pipeline for a single VPS (the research is explicit that Packer is excessive
at that scale).

## Scope (once justified)

**In:**
- A Packer template running the modules unchanged as a `shell` provisioner against a
  Hetzner snapshot builder, producing a versioned hardened image.
- Build metadata / version stamp recorded for chain-of-custody.

**Out:**
- Changing any module (the design constraint is that modules run unmodified in Packer).

## Acceptance criteria

1. `packer build` yields a Hetzner image that boots and passes `make audit` (Lynis ≥ 75)
   with no post-boot hardening step.
2. Image carries a version + source-commit stamp.

## Definition of done

- [ ] Justification recorded · image builds and audits clean · STYLE.md clean
