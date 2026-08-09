# Lynis hardening-index baseline

Recorded from the tier-3 acceptance (`scripts/test-hetzner.sh`). A PR must not drop
the index below the recorded value for its distro, and must not add a new unaddressed
warning. Floor: 75 (see docs/TESTING.md).

| Date | Distro | Server | Index | Open warnings | Notes |
|---|---|---|---|---|---|
| 2026-08-09 | ubuntu-24.04 (noble) | cpx11 | **78** | 1 | only PKGS-7388 (false positive, below) |

## Known false positive: PKGS-7388

> Can't find any security repository in /etc/apt/sources.list or sources.list.d

Ubuntu 24.04 ships APT sources in the `deb822` format at
`/etc/apt/sources.list.d/ubuntu.sources`, which the packaged Lynis does not parse for
the `-security` pocket. Security updates *are* configured and applied
(unattended-upgrades pulls `-security`; verified in 10-update). We do not add a legacy
`.list` stub purely to satisfy the scanner — that would be theatre, not hardening.

## Deliberately not chased (would raise the score, but rejected — see ASSESSMENT §7)

- **FILE-6310** separate /home /var /tmp partitions — cannot retrofit onto a stock cloud image.
- **BOOT-5122** GRUB password — pointless on a headless cloud VM (console rescue is provider-gated).
- **DEB-0880** copy jail.conf to jail.local — the full-copy anti-pattern we explicitly avoid.
- **DEB-0810/0811** apt-listbugs / apt-listchanges — interactive APT hooks that can stall
  unattended-upgrades on an auto-patching server.
- **AUTH-9262** pam_passwdqc/cracklib — password-quality PAM on a keys-only box adds little.
