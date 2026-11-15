# Raspberry Pi kiosk profile

How to harden a Raspberry Pi 4 kiosk running Raspberry Pi OS (Debian 13 "trixie", arm64)
with this baseline. The variable set is in
[`examples/raspberry-pi-kiosk.env`](../examples/raspberry-pi-kiosk.env). Rationale and
scope: [ticket 016](../tickets/016-raspberry-pi-kiosk-profile.md).

## What has and has not been run

**Nothing here has been run on a physical Raspberry Pi.** What has been run:

- On 15-11-2026 the profile was applied inside a Debian 13 (trixie) arm64 virtual
  machine booted from the userspace of a Raspberry Pi OS kiosk image (not a Pi, and not
  the Pi kernel): `make harden` exited 0, `make audit` passed (36 passed, 0 failed,
  2 skipped), Lynis hardening index 75, SSH stayed reachable, and the audit passed again
  after a reboot. On the same day the corrected `52-vmt-autoupgrade` was checked on a Debian 13
  container: `unattended-upgrade --dry-run -d` parses it and lists the Debian origins and the
  blacklist, and aborts with "Unable to parse Unattended-Upgrade::Allowed-Origins" on the old
  form. The VM run found four defects, fixed on this branch: unattended-upgrades
  rejected its own configuration (`Allowed-Origins` with `origin=` strings; present on
  `develop` too), the admin's narrow sudo rule was widened to `NOPASSWD: ALL`
  (`ADMIN_SUDO=keep`), the previous kernel was removed
  (`UPGRADE_REMOVE_UNUSED_KERNELS=0`), and `30-ssh` pinned host key paths that did not
  exist. Not covered by that run: the Pi kernel, firmware, boot chain, display, Wi-Fi,
  the SD card, and a rerun of the VM against these fixes.

What exists besides:

- The bats suite covers every new variable with `DRY_RUN=1` and stubbed commands: the
  default, the set value and the rejected value, the skip logic in `make harden` and
  `make audit`, the Raspberry Pi origin drop-in, the blacklist rendering and the
  journald audit.
- A CI job applies this profile with `make harden` and `make audit` on the
  `ubuntu-24.04-arm` runner. That runner is a real arm64 machine running **Ubuntu 24.04,
  not Raspberry Pi OS**. It has no Raspberry Pi archive and a different kernel, so it
  proves the profile's variables work on arm64 Debian-family hosts, nothing about Pi OS.
  (It sets `SSH_ALLOW_FROM` and `FAIL2BAN_IGNOREIP` to the runner's own loopback so the
  job cannot cut itself off; it does not run the example file's placeholder addresses.)
- The origin strings come from the archive's published `Release` file (below). That the
  drop-in then matches packages on a Pi is not tested: `unattended-upgrade --dry-run
  --debug` on the device is the check.

Still to do on a board (the VM run above covers the userspace only), in this order:
`make harden` on a fresh image from a console you can reach (not only SSH); `make audit`; reboot and `make audit` again; a second
`make harden` that prints `OK` throughout; `unattended-upgrade --dry-run --debug`
showing the Raspberry Pi origin allowed and a held package refused.

## What the profile sets

| Variable | Value in the example | Effect |
|---|---|---|
| `SKIP_MODULES` | `docker` | The listed modules do not run. `make audit` reports their controls as `[skip]` with the reason, never as failures. Names: `update user ssh firewall fail2ban sysctl hardening docker auditd`. An unknown name fails preflight and the audit. `00-preflight` and `90-report` cannot be skipped. |
| `JOURNAL_STORAGE` | `volatile` | journald keeps its journal in RAM, capped by `JOURNAL_VOLATILE_MAX_USE` (default `32M`), through a drop-in. Default is `persistent`, unchanged. The audit accepts whichever value was asked for. Volatile logs are gone after a reboot. |
| `UPDATE_SKIP_DIST_UPGRADE` | `1` | `10-update` skips the immediate `dist-upgrade`. The unattended-upgrades policy is still installed. Default `0`. |
| `UPGRADE_HOLD_PACKAGES` | kernel, firmware, bootloader globs | Written to `Unattended-Upgrade::Package-Blacklist`. Default empty (no blacklist). |
| `ADMIN_SUDO` | `keep` | `20-user` leaves the admin's sudo group and sudoers rules as found, for an image that ships a narrow rule. `make audit` then reports "can escalate to root" as informational. Values: `keep`, `nopasswd`, `password`; unset keeps the default model. |
| `UPGRADE_REMOVE_UNUSED_KERNELS` | `0` | unattended-upgrades keeps the previous kernel (`Remove-Unused-Kernel-Packages "false"`). Default `1`. |
| `FAIL2BAN_IGNOREIP` | one address | Added, after `127.0.0.1/8 ::1`, to the sshd jail's `ignoreip`. Default empty. |
| `SSH_ALLOW_FROM` | one CIDR | `40-firewall` allows the SSH port only from these sources and deletes an earlier open-to-anywhere SSH rule. Default empty (open to anywhere, as before). |
| `BLOCK_USB_STORAGE` | `auto` | Existing knob, see [HARDENING.md](HARDENING.md) §65-hardening. |

### Raspberry Pi archive in unattended-upgrades

`10-update` writes `/etc/apt/apt.conf.d/53-vmt-raspberrypi-origin` only when the
Raspberry Pi archive is configured on the host. It looks at `apt-cache policy` and at
`/etc/apt/sources.list` and `/etc/apt/sources.list.d` for `archive.raspberrypi.com` (or
the older `.org` name). Nothing is assumed from the distro, and the drop-in is removed
again if the archive goes away.

The strings come from `https://archive.raspberrypi.com/debian/dists/trixie/Release`
(fetched 2026-11-15; `InRelease` carries the same fields):

```
Origin: Raspberry Pi Foundation
Label: Raspberry Pi Foundation
Suite: stable
Codename: trixie
```

`Suite` is `stable`, not `trixie`, so the pattern matches on the codename:

```
Unattended-Upgrade::Origins-Pattern:: "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
```

The drop-in is separate from `52-vmt-autoupgrade` on purpose: that file replaces the
Debian origins on every run, and the Raspberry Pi origin has to exist only on hosts that
use the archive.

### Holding kernel, firmware and bootloader back

`UPGRADE_HOLD_PACKAGES` takes shell-style globs (letters, digits, `. + - : * ?`). They
become the regular expressions `unattended-upgrade` expects: `raspi-firmware` becomes
`raspi-firmware$`, `linux-image-*` becomes `linux-image-.*$`. unattended-upgrade matches
from the start of the package name, so the end anchor is what stops `libc6` from also
holding `libc6-dev`.

The patterns in the example come from the package names in the archive's trixie arm64
index (2026-11-15): kernels are `linux-image-rpi-v8`, `linux-image-rpi-2712` and their
versioned forms (`linux-image-6.18.60+rpt-rpi-v8`), headers and `linux-base-*` follow the
same scheme, the firmware package is `raspi-firmware`, and the bootloader EEPROM
packages are `rpi-eeprom` and `rpi-eeprom-images`. They are **examples to be confirmed
against `dpkg -l` on the image**, which may carry other names.

A held package is not upgraded by unattended-upgrades. It stays at its installed
version until someone upgrades it by hand, so a security fix in the kernel needs that
supervised step.

### Locking yourself out

`SSH_ALLOW_FROM` removes the open SSH rule. If the session running `make firewall` does
not come from one of the listed sources, it is cut off when the old rule goes, and the
only way back is the console. Run it from a host inside the range, or from the console.
`FAIL2BAN_IGNOREIP` has no such risk but widens what fail2ban ignores: only list
addresses you control.

## What vm-template does not cover on a kiosk

These stay with the layer that builds the kiosk:

- the kiosk user and its (no-sudo) permissions, and autologin;
- the browser and its policies, kiosk-mode flags, and the display session;
- a hardware watchdog and the service restart policy;
- read-only root or any other flash-wear measure beyond the journal;
- running the modules inside an image build: they need a running systemd and reload
  sshd and ufw, so they run on a booted system (first boot or later), not in a chroot;
- network and Wi-Fi setup, mDNS (ufw denies inbound mDNS: add
  `EXTRA_PORTS="5353/udp"` if the device must resolve by name).

## Usage

```bash
set -a; . examples/raspberry-pi-kiosk.env; set +a   # edit the PLACEHOLDER lines first
sudo -E make harden
sudo -E make audit
```

`sudo -E` keeps the exported variables. `make audit` must be given the same variables as
`make harden`: a skipped module and the journald mode are read from the environment, and
an audit run without them judges the host against the defaults.
