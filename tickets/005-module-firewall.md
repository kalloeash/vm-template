# 005 — `40-firewall`: ufw + Docker DOCKER-USER integration

**Status:** ready
**Depends on:** 001

## Context

ufw alone does not gate Docker-published ports: Docker writes DNAT rules into the FORWARD
chain, which ufw's INPUT rules never see (assessment §2, research sources). A container
published on `0.0.0.0` is internet-reachable regardless of ufw. encryptedlinkvm already
dodges this by binding containers to `127.0.0.1`; this module enforces the base firewall
and makes the Docker interaction explicit rather than incidental.

## Scope

**In:**
- ufw `default deny incoming`, `default allow outgoing`; allow `22/tcp` plus
  `EXTRA_PORTS` (default `80/tcp 443/tcp`); enable non-interactively (`--force`).
- Detect any `docker-compose.y*ml` under `/opt` and **warn** on any `ports:` entry that
  is not bound to `127.0.0.1`.
- Optional `UFW_DOCKER=1`: install the chaifeng/ufw-docker DOCKER-USER wiring for hosts
  that must publish container ports through ufw.

**Out:**
- Egress filtering (`default deny outgoing`) — rejected in assessment §7.
- Per-container network policy (belongs to the app's compose, not the host baseline).

**Note (from research):** a `127.0.0.1` publish can affect container-to-container
networking in some topologies, and if a port must be published publicly the `ufw-docker`
tool is required rather than hand-written `after.rules` — container IPs change on restart,
so static rules rot. `UFW_DOCKER=1` therefore installs the tool, it does not hand-roll rules.

## Acceptance criteria

1. After `make firewall`, `ufw status verbose` shows `Default: deny (incoming)` and the
   expected allow rules; `ufw status | grep -c 22/tcp` ≥ 1.
2. Re-running does not duplicate rules (`ufw status numbered` count stable across two runs).
3. A compose file publishing `0.0.0.0:5432:5432` under `/opt` produces a `WARN:` line
   naming the file and port; a `127.0.0.1`-bound file produces none.
4. With `UFW_DOCKER=1`, the DOCKER-USER chain contains the ufw-docker jump
   (`iptables -S DOCKER-USER` includes the managed rules).

## Test plan

- **WSL (Tier 2):** file-state and warn-logic only (ufw runtime is not representative on
  the shared WSL kernel — assert rule *files* / dry-run output, defer runtime to Tier 3).
- **Hetzner (Tier 3):** enable, then from a second host confirm 22/80/443 reachable and a
  test container published on `0.0.0.0:9999` is **not** reachable after `UFW_DOCKER=1`.

## Definition of done

- [ ] Acceptance criteria 1–4 pass
- [ ] `make lint` clean · idempotent · `DRY_RUN=1` supported
- [ ] Docker-bypass rationale + `UFW_DOCKER` usage in HARDENING.md
- [ ] STYLE.md clean
