# 008 — `70-docker`: repo install + `daemon.json` caps

**Status:** ready
**Depends on:** 001

## Context

Generalizes the encryptedlinkvm Docker install and closes the unbounded-logs gap
(assessment §2, "most common self-inflicted VPS outage"): no `daemon.json` means
uncapped json-file logs that eventually fill the disk.

## Scope

**In:**
- Official Docker apt repo per distro (ubuntu/debian; Kali → debian codename mapping),
  install engine + buildx + compose plugin, enable the service.
- `/etc/docker/daemon.json`: `log-driver json-file`, `log-opts max-size 10m` /
  `max-file 3`, `live-restore true`, `no-new-privileges true`. Merge, don't clobber, if
  the file already exists.
- `docker run --rm hello-world` smoke test.

**Out:**
- Adding users to the `docker` group by default (root-equivalent; assessment §3.3).
  `DOCKER_GROUP_USER` opt-in with a printed warning.

## Acceptance criteria

1. `docker version` shows engine + compose plugin installed from the official repo.
2. `daemon.json` contains the four keys; `docker info` reflects the log driver + opts.
3. `--password-stdin` is used anywhere a registry login is scripted (no PAT in argv —
   assessment §3.1).
4. Idempotent; existing `daemon.json` keys are preserved on merge.

## Test plan

- **Tier 2 (WSL):** repo + package assertions; `daemon.json` merge logic on a seeded file.
- **Tier 3 (Hetzner):** full install + `hello-world` + `docker info` log-opt check.

## Definition of done

- [ ] Acceptance criteria pass on Ubuntu 24.04, Debian 13 · `make lint` clean · idempotent
      · `DRY_RUN=1` · STYLE.md clean
