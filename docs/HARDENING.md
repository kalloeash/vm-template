# Module specifications

Every module: idempotent, standalone, prints one `CHANGED:`/`OK:` line per step, exits
non-zero on failure, supports `DRY_RUN=1`. Config knobs are environment variables with
safe defaults (documented per module). Ordering = numeric prefix.

## 00-preflight
- Assert: running as root (or sudo), supported distro (`/etc/os-release` ID in
  ubuntu/debian/kali), apt available, systemd running.
- **Lockout guard**: record whether the current SSH session is key-authenticated and
  whether the target admin user has a non-empty `authorized_keys`. Modules that would
  cut password access refuse to proceed unless one of those is true (override:
  `FORCE_LOCKOUT_OK=1`).

## 10-update
- `apt-get update` + `dist-upgrade -y` (with dpkg options to keep local config files).
- Install + enable `unattended-upgrades`; deploy the `52autoreboot.conf` policy from
  the reference deployment (also `-updates`, auto-reboot 04:00, kernel/dependency cleanup).
  On Kali: origins pattern adapted to kali-rolling, auto-reboot off by default.
- Install `needrestart`, set `$nrconf{restart} = 'a'` (automatic service restarts).
- Verify systemd-timesyncd (or chrony if present) is active and synchronized.

## 20-user
- Create admin user (`ADMIN_USER`, default `admin`; on Kali reuse `kali`), add to sudo,
  copy root's `authorized_keys` if the user has none.
- No password set (keys only); `sudo` NOPASSWD optional (`SUDO_NOPASSWD=1`, default off).

## 30-ssh
- Drop-in `/etc/ssh/sshd_config.d/10-hardening.conf` (never edit the main file):
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`,
  `PubkeyAuthentication yes`, `MaxAuthTries 3`, `LoginGraceTime 30`,
  `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `X11Forwarding no`,
  `AllowAgentForwarding no`, `PermitEmptyPasswords no`,
  optional `AllowUsers ${ADMIN_USER}` (`SSH_ALLOW_USERS=1`).
- Modern algorithms (curve25519/aes-gcm/chacha20/ed25519 family) — the exact set is
  whatever current `ssh-audit` passes clean on the target OpenSSH version.
- Regenerate weak host keys if present (drop small-moduli, keep ed25519 + rsa-4096).
- `sshd -t` gate before restart; **lockout guard consulted before applying**.

## 40-firewall
- ufw: `default deny incoming`, `default allow outgoing`, allow `22/tcp` +
  `EXTRA_PORTS` (default `80/tcp 443/tcp`), enable non-interactively.
- **Docker integration**: document the FORWARD-chain bypass; assert that any
  `docker-compose.yml` found under `/opt` publishes only on `127.0.0.1` (warn
  otherwise). Optional `UFW_DOCKER=1` installs the chaifeng/ufw-docker DOCKER-USER
  chain wiring for hosts that must publish container ports.

## 50-fail2ban
- Install; deploy `jail.d/sshd.local` (maxretry 3 / findtime 600 / bantime 3600,
  incremental to 5w). `backend = systemd` (mandatory on 24.04 — sshd logs to the journal,
  not `/var/log/auth.log`) and `allowipv6 = auto` (silences the dual-stack warning).
- No `jail.conf → jail.local` full copy (upstream anti-pattern).

## 60-sysctl
- `/etc/sysctl.d/99-hardening.conf`: rp_filter=1, accept_redirects=0 (v4+v6),
  send_redirects=0, accept_source_route=0 (v4+v6), log_martians=1, tcp_syncookies=1,
  icmp_echo_ignore_broadcasts=1, kptr_restrict=2, dmesg_restrict=1,
  kernel.yama.ptrace_scope=1, unprivileged_bpf_disabled=1, fs.protected_symlinks=1,
  fs.protected_hardlinks=1.
- NOT included (documented): `disable_ipv6` (breaks dual-stack hosts),
  `unprivileged_userns_clone=0` (breaks rootless container tooling).
- Apply with `sysctl --system`; on WSL only write files (shared kernel).

## 65-hardening
- CIS-Level-1 odds and ends that the Lynis audit flags on a fresh image:
  - **login.defs**: `UMASK 027`, `PASS_MAX_DAYS 365`, `PASS_MIN_DAYS 1`,
    `PASS_WARN_AGE 7`, `SHA_CRYPT_MIN_ROUNDS 640000` (AUTH-9230/9286/9328).
  - **core dumps off**: `limits.d` `* hard/soft core 0` (KRNL-5820), paired with
    `fs.suid_dumpable=0` in 60-sysctl.
  - **kernel-module blacklist**: rare network protocols dccp/sctp/rds/tipc
    (NETW-3200) and usb-storage (USB-1000), via `install … /bin/true`.
- Packages installed in 10-update on the same audit advice: `libpam-tmpdir`,
  `debsums`, `apt-show-versions`.

## 70-docker
- Official Docker apt repo (per-distro: ubuntu/debian; Kali uses the debian repo with
  its codename mapped), install engine + compose plugin.
- `/etc/docker/daemon.json`: `log-driver json-file` + `max-size 10m` / `max-file 3`,
  `live-restore true`, `no-new-privileges true`.
- Do NOT add users to the docker group by default (root-equivalent); `DOCKER_GROUP_USER`
  opt-in with a warning.

## 80-auditd (optional tier: `make harden TIER=full`)
- auditd + minimal ruleset: identity files (passwd/group/sudoers), sshd_config,
  docker daemon config, privileged execs. journald `Storage=persistent` always (base tier).

## 90-report
- Print per-module status table, `lynis audit system --quick` hardening index,
  `ssh-audit localhost` summary, reboot-required flag.

## Deliberately skipped (see ASSESSMENT.md §7)
SSH port change · egress filtering · CIS L2 · partitioning · rkhunter · SELinux ·
MOTD legal banners (add if an org ever requires them).
