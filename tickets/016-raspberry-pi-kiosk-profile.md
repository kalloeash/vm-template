# 016 — Raspberry Pi kiosk profile

**Status:** in-progress (implemented and tested in CI; acceptance on a physical Raspberry Pi is open)
**Depends on:** 002, 005, 006, 009

## Run on 15-11-2026

The profile was applied in a Debian 13 arm64 VM booted from the userspace of a Raspberry
Pi OS kiosk image: `make harden` exit 0, `make audit` PASS 36/0/2, Lynis 75, SSH kept,
reboot fine. It found four defects, fixed on this branch with bats tests: (1)
`Allowed-Origins` with `origin=` strings broke unattended-upgrades (also on `develop`),
(2) `20-user` widened the admin's sudo (`ADMIN_SUDO`), (3) the previous kernel was removed
(`UPGRADE_REMOVE_UNUSED_KERNELS`), (4) `30-ssh` pinned host key paths that do not exist.
Still not run: a physical Pi and the Pi kernel (criterion 9).

## Context

A Raspberry Pi 4 kiosk running Raspberry Pi OS (Debian 13 trixie, arm64) is hardened at
first boot with this baseline. Reading the modules against that case turned up three gaps
and one first-boot risk ([ASSESSMENT.md](../docs/ASSESSMENT.md), Raspberry Pi section;
[HARDENING.md](../docs/HARDENING.md)):

1. The module list is fixed in the Makefile; a kiosk with no containers cannot leave
   `70-docker` out, and the audit would still report on it.
2. `10-update` lists Debian origins only. On Raspberry Pi OS the kernel, firmware and
   `rpi-*` packages come from `archive.raspberrypi.com`, which unattended-upgrades would
   never touch. There is also no way to keep kernel, firmware and bootloader packages out
   of unattended upgrades, and a freshly built image blocks its first boot on
   `dist-upgrade`.
3. `80-auditd` forces persistent journald and the audit requires it. On an SD card that
   is constant write wear.
4. On a single-admin LAN device, three mistyped passphrases ban the only way in, and SSH
   is open to the whole network.

## Scope

**In:**
- `SKIP_MODULES` (validated against the known names), honoured by `make harden`, single
  module targets and `make audit` / `90-report` (`[skip]` with the reason).
- `10-update`: Raspberry Pi archive origin in a separate drop-in, only when apt shows the
  archive; `UPGRADE_HOLD_PACKAGES`; `UPDATE_SKIP_DIST_UPGRADE=1`.
- `JOURNAL_STORAGE=persistent|volatile` and `JOURNAL_VOLATILE_MAX_USE`; the audit accepts
  the configured mode.
- `FAIL2BAN_IGNOREIP`, `SSH_ALLOW_FROM`.
- `examples/raspberry-pi-kiosk.env`, `docs/RASPBERRY-PI.md`, bats tests, one CI job.

**Out:**
- The kiosk user, autologin, browser policies, watchdog, read-only root: the layer that
  builds the kiosk owns them ([RASPBERRY-PI.md](../docs/RASPBERRY-PI.md)).
- Running the modules in an image-build chroot (they need a running systemd).
- Any change to the default behaviour of an existing host.

## Evidence for the Raspberry Pi origin

Fetched 2026-11-15 from `https://archive.raspberrypi.com/debian/dists/trixie/Release`
(`InRelease` is the same text, signed):

```
Origin: Raspberry Pi Foundation
Label: Raspberry Pi Foundation
Suite: stable
Codename: trixie
Architectures: armhf arm64 i386 amd64
Components: main beta untested
```

`Suite` is `stable`, so a `codename=${distro_codename}` pattern is what matches a trixie
host; the pattern written is
`origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation`.
The same file is served at `archive.raspberrypi.org`; detection accepts both host names.

Example hold patterns come from the package names in that archive's
`main/binary-arm64/Packages` on the same date: `linux-image-rpi-v8`,
`linux-image-rpi-2712`, versioned `linux-image-<version>+rpt-rpi-*`,
`linux-headers-*`, `linux-base-*`, `raspi-firmware`, `rpi-eeprom`, `rpi-eeprom-images`.
They are placeholders until checked against the image's `dpkg -l`.

## Decisions

1. **Skip is a gate in each module, not a Makefile filter.** The same check then works
   for `make harden`, `make <module>` and any caller that runs the scripts directly, and
   the audit shares the helper (`module_skipped` in `lib/common.sh`).
2. **Volatile journald uses a drop-in; persistent keeps editing the main file.** The
   persistent path is unchanged byte for byte. A drop-in overrides the main file, so
   volatile does not need to touch it, and the drop-in is removed when the mode goes
   back.
3. **The origin drop-in is `53-vmt-raspberrypi-origin`, not part of `52-vmt-autoupgrade`.**
   The brief for this ticket cites a `52autoreboot.conf` precedent that adds a third-party
   origin; that file belongs to the reference deployment this baseline grew out of and is
   not in this repository. Here the equivalent policy file is `52-vmt-autoupgrade`, which
   is rewritten on every run for every host, so a Pi-only origin goes in its own file that
   exists only when the archive is configured.
4. **`UPGRADE_HOLD_PACKAGES` takes globs and renders anchored regexes.** The apt option
   takes Python regexes matched from the start of the name (checked in the
   unattended-upgrade source), where `libc6` would also hold `libc6-dev`.
5. **`SSH_ALLOW_FROM` deletes the open rule.** Adding source rules next to an existing
   open rule would restrict nothing. The module adds the new rules first, then deletes,
   and warns that the running session must come from a listed source.

## Acceptance criteria

1. Every new variable, unset, leaves the output of each module as before. ✅ bats
   (`tests/module-*.bats`); `52-vmt-autoupgrade`, the jail and the firewall rules are
   byte-identical when the variables are unset.
2. `SKIP_MODULES=docker make harden` runs everything but 70-docker; `make audit` with the
   same value prints `[skip] docker installed (module docker skipped: SKIP_MODULES)` and
   exits 0 when everything else passes; `SKIP_MODULES=dockr` fails preflight and the
   audit. ✅ bats, ✅ CI job `kiosk-profile`
3. The Raspberry Pi drop-in exists only when `apt-cache policy` or the apt sources name
   the archive. ✅ bats (policy, deb822, one-line, commented-out, absent)
4. `UPGRADE_HOLD_PACKAGES="linux-image-* raspi-firmware"` yields `"linux-image-.*$";` and
   `"raspi-firmware$";` in `Package-Blacklist`; a non-package pattern is rejected. ✅ bats
5. `UPDATE_SKIP_DIST_UPGRADE=1` skips the dist-upgrade and nothing else; `0` and unset
   behave as before; other values are rejected. ✅ bats
6. `JOURNAL_STORAGE=volatile` writes the capped drop-in, and `make audit` passes with it
   and fails when the drop-in is missing or the cap differs; default unchanged. ✅ bats
7. `FAIL2BAN_IGNOREIP` and `SSH_ALLOW_FROM` are validated as IPv4/IPv6 addresses or CIDRs;
   `SSH_ALLOW_FROM` replaces the open rule. ✅ bats
8. The kiosk variable set applied on the arm64 Ubuntu runner: harden, a second run with
   no `CHANGED:`, `make audit` passing, `make audit` failing when ufw is off. ✅ CI
   (`kiosk-profile`)
9. On a physical Raspberry Pi 4 with Raspberry Pi OS trixie arm64: `make harden`,
   `make audit`, a reboot and `make audit` again, a second `make harden` all `OK`, and
   `unattended-upgrade --dry-run --debug` showing the Raspberry Pi origin allowed and a
   held package refused. ⬜ **not run** (tier 3, needs the board; deferred to a
   maintainer)

## Test plan

- **Tier 1/2:** `make test`, `make lint`, `pre-commit run --all-files`.
- **CI:** the existing `harden` matrix is unchanged; `kiosk-profile` runs the profile on
  `ubuntu-24.04-arm`.
- **Tier 3:** criterion 9, by hand on the board.

## Definition of done

- [ ] Acceptance criteria pass (1-8 do; 9 needs a physical board)
- [x] `make lint` clean (shellcheck + shfmt)
- [x] Idempotent: second run prints `OK` for every step
- [x] `DRY_RUN=1` supported
- [x] Conforms to [STYLE.md](../docs/STYLE.md) (no AI attribution / AI-tell words)
- [x] Module rationale added to [HARDENING.md](../docs/HARDENING.md)
