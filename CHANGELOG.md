# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow [SemVer](https://semver.org). Dates are ISO-8601.

## [Unreleased]

### Added — Raspberry Pi kiosk profile (ticket 016)

- `SKIP_MODULES="docker"` leaves modules out of `make harden`; `make audit` reports their
  controls as `[skip]` with the reason. Unknown names fail preflight.
- `10-update`: `UPDATE_SKIP_DIST_UPGRADE=1` skips the immediate `dist-upgrade`;
  `UPGRADE_HOLD_PACKAGES` writes `Unattended-Upgrade::Package-Blacklist`; a separate
  drop-in adds the Raspberry Pi archive origin when apt shows the archive is configured.
- `JOURNAL_STORAGE=volatile` (with `JOURNAL_VOLATILE_MAX_USE`, default `32M`) for devices
  on flash media; the audit accepts the configured mode. Default stays `persistent`.
- `FAIL2BAN_IGNOREIP` for the sshd jail and `SSH_ALLOW_FROM` to open the SSH port only
  from given sources. Defaults keep today's behaviour.
- `examples/raspberry-pi-kiosk.env` and `docs/RASPBERRY-PI.md`. A CI job applies the
  profile on the arm64 Ubuntu runner (not Raspberry Pi OS).
- Known gap: none of this has run on a physical Raspberry Pi or on Raspberry Pi OS.

## [1.0.0] — 2026-08-10

First release considered safe to point at a machine you care about. The modules existed
before this; what changed is that the claims around them are now true and checked.

### Fixed — access and correctness

- **The admin could not reach root.** The account was created with a locked password
  while `sudo` still demanded one, so once root SSH was disabled the host had no path to
  root at all. The password state and the sudo policy are now derived together: key-only
  accounts get a `NOPASSWD` drop-in, `ADMIN_PASSWORD_HASH` selects a password account,
  and the broken combination is refused rather than shipped.
- **A rejected sshd config survived on disk.** `30-ssh` wrote the drop-in and validated
  afterwards, so a config `sshd -t` refused stayed in place and would have taken SSH down
  at the next reboot. The install is transactional now — back up, write, validate, roll
  back on failure.
- **`make audit` never failed.** It printed `[MISS]` for broken controls and exited 0.
  It now has an exit contract: 0 only when every mandatory control is in the expected
  state. Informational findings are separated so the gate stays meaningful.
- **Modules reported changes that never happened.** Four modules logged a change on every
  run, making the project's own idempotence criterion unreachable — and two of them
  restarted a service each time, dropping fail2ban's ban list and bouncing every
  container. Changes are now detected before they are claimed.
- **ufw silently reverted a hardening control.** ufw applies its own
  `/etc/ufw/sysctl.conf` on every enable and reload, setting `log_martians=0` over the
  value `60-sysctl` sets. Any `ufw reload` in production dropped it. ufw no longer owns
  sysctl policy.
- **`ADMIN_PASSWORD_HASH` could not be used as documented.** `make` expands `$` in
  command-line variables, so the documented invocation delivered a mangled hash. Docs use
  the environment form; `ADMIN_PASSWORD_HASH_FILE` added.
- Weak Diffie-Hellman groups (Logjam) are pruned from `/etc/ssh/moduli`; a file that
  would end up empty is left alone instead.
- `usb-storage` is no longer blocked on hosts that boot from USB, which would have made
  a Raspberry Pi booting from an SSD unbootable.

### Changed — defaults and claims

- **`EXTRA_PORTS` defaults to empty.** Only SSH is opened; 80/443 came from the web
  server this baseline grew out of and are not a hardening default. Existing hosts keep
  their rules.
- `ufw-docker` is pinned to a tagged commit and checksum-verified before it executes,
  instead of being fetched from `master` and run as root.
- The Docker/ufw section says what it actually does: it **detects** a non-loopback
  publish (compose files and running containers) and warns; it enforces only under
  `UFW_DOCKER=1`.
- Documentation was reconciled with the code — the SSH host-key claim, what the lockout
  guard proves, and the arm64 support statement.

### Added — verification

- `tests/` — 54 bats tests over the shared library, the privilege models, the firewall
  logic, the SSH refusals and a contract every module must keep. `make test`.
- CI on every PR: lint, pre-commit, the unit suite, a dry run, and the **real baseline
  applied on both amd64 and arm64**, including an idempotence check and a check that the
  audit fails when a control is broken.
- `make audit` verifies every sysctl the baseline sets, not one; plus host-key
  algorithms, moduli floor, core dumps, module blacklist, `login.defs`, and the admin's
  path to root.
- `scripts/test-hetzner.sh` — one-command acceptance against a disposable VM, with
  `EXTENDED=1` adding deliberate-break drills (audit gate, sshd rollback, both privilege
  models, `TIER=full`).
- `scripts/test-cloud-init.sh` — first-boot delivery verified end to end.

### Known gaps

Stated here rather than discovered later:

- The SSH lockout drill has not been run on arm64; it needs a VM reachable from outside
  and ARM capacity was unavailable. Everything else about arm64 is exercised on real
  aarch64 hardware in CI.
- No physical Raspberry Pi has run this. The `linux-raspi` kernel's sysctl coverage and
  the USB-root detection in `65-hardening` can only be confirmed on a board.
- Docker/ufw enforcement is opt-in, not the default.
- CrowdSec evaluation (ticket 012) and the Packer path (ticket 014) are drafts.
