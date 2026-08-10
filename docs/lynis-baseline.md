# Lynis hardening-index baseline

Recorded from the tier-3 acceptance (`scripts/test-hetzner.sh`). A PR must not drop
the index below the recorded value for its distro, and must not add a new unaddressed
warning. Floor: 75 (see docs/TESTING.md).

| Date | Distro | Server | Index | Open warnings | Notes |
|---|---|---|---|---|---|
| 2026-08-09 | ubuntu-24.04 (noble) | cpx11 | **78** | 1 | only PKGS-7388 (false positive, below) |
| 2026-08-10 | ubuntu-24.04 (noble) | cpx11 | **78** | 1 | after the review remediation series; index held, 4 runs |
| 2026-08-10 | debian-13 (trixie) | cpx11 | **78–79** | 1 | first recorded Debian baseline; 79 on the standard run, 78 with `EXTENDED=1` |

The Debian pair is not a regression: the `EXTENDED=1` run deliberately breaks and
restores controls (ufw down, a rejected sshd drop-in) before Lynis runs, and one point of
the index moves with it. Compare like for like — standard runs against standard runs.

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
