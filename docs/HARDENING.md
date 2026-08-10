# Module specifications

Every module: idempotent, standalone, prints one `CHANGED:`/`OK:` line per step, exits
non-zero on failure, supports `DRY_RUN=1`. Config knobs are environment variables with
safe defaults (documented per module). Ordering = numeric prefix.

**What the two words mean.** `CHANGED:` = this run altered system state. `OK:` = the
state was already correct. A second `make harden` printing only `OK` is the idempotence
check, which only holds if a module never reports a change it did not make. In practice:
package upgrades are simulated with `apt-get -s` before running, a service is restarted
only when its config file changed or the unit is down, and `install_file` exports
`VMT_FILE_CHANGED` so callers can make that decision.

## 00-preflight
- Assert: running as root (or sudo), supported distro (`/etc/os-release` ID in
  ubuntu/debian/kali), apt available, systemd running.
- **Lockout guard**: check whether `root` or the target admin user has an
  `authorized_keys` file containing at least one recognized key type. Modules that would
  cut password access refuse to proceed unless that holds (override:
  `FORCE_LOCKOUT_OK=1`).
  - What this proves: key-based access is *possible* for one of those accounts.
  - What it does not prove: that the session running `make harden` is itself
    key-authenticated, or that the key on disk is one you hold. The guard reads the file;
    it does not inspect the current connection. An operator on a password session with a
    stale key in `authorized_keys` can still lock themselves out — the drill in
    [TESTING.md](TESTING.md) exists for that reason.

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
- Two privilege models, picked by whether a password exists:
  - **key-only** (default): the account is created with a locked password, so `sudo`
    gets a `NOPASSWD` drop-in — otherwise the admin could log in by key and then have
    nothing to type at the `sudo` prompt.
  - **password**: set `ADMIN_PASSWORD_HASH` to a crypt(3) hash (`openssl passwd -6`);
    the password is applied with `chpasswd -e` and `sudo` asks for it.
- `SUDO_NOPASSWD` still overrides the default, but the combination "no usable password
  and `SUDO_NOPASSWD=0`" is rejected with a fatal error rather than shipped: after
  30-ssh disables root login it leaves no path to root.
- A pre-existing account's password state is never changed; the model is derived from
  what `passwd -S` reports.

## 30-ssh
- Drop-in `/etc/ssh/sshd_config.d/10-hardening.conf` (never edit the main file):
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`,
  `PubkeyAuthentication yes`, `MaxAuthTries 3`, `LoginGraceTime 30`,
  `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `X11Forwarding no`,
  `AllowAgentForwarding no`, `PermitEmptyPasswords no`,
  optional `AllowUsers ${ADMIN_USER}` (`SSH_ALLOW_USERS=1`).
- Modern algorithms (curve25519/aes-gcm/chacha20/ed25519 family) — the exact set is
  whatever current `ssh-audit` passes clean on the target OpenSSH version.
- **Host keys**: the drop-in pins `HostKey` to the ed25519 and RSA keys, so sshd stops
  offering the ecdsa (nistp256) key that `ssh-audit` flags. That is a change in what the
  daemon *offers*; the module does not generate, rotate or delete any key material, and
  it does not touch `/etc/ssh/moduli`. Regenerating weak host keys and pruning small
  moduli are open work — [ticket 015](../tickets/015-ssh-host-key-hygiene.md).
- `sshd -t` gate before reload; **lockout guard consulted before applying**.
- The drop-in is installed transactionally: the previous version is kept, `sshd -t`
  validates the effective config (the include chain, not the fragment alone), and a
  rejected drop-in is restored or removed before the module exits non-zero. A config the
  daemon refuses must never stay on disk — the running sshd survives, but the next
  reboot or `systemctl restart ssh` would not.
- Reload runs on every invocation so the daemon converges after an earlier failed
  reload, but only a real content change reports `CHANGED`.

## 40-firewall
- ufw: `default deny incoming`, `default allow outgoing`, allow `${SSH_PORT}/tcp` +
  `EXTRA_PORTS` (**default empty**), enable non-interactively. Only SSH is open unless
  the caller asks for more: 80/443 belong to a web host's build sheet, not to a generic
  hardened VM.
- **Docker integration**: Docker's DNAT rules live in the FORWARD/DOCKER chains, which
  ufw's INPUT policy never sees, so a container published on `0.0.0.0` is reachable
  whatever ufw says. What this module actually does about that, stated plainly:
  - **Detects** the exposure two ways — compose files under `COMPOSE_SCAN_DIRS`
    (`/opt /srv /root /home`, depth 3, `docker-compose.y*ml` and `compose.y*ml`) and,
    separately, containers publishing a non-loopback port right now (`docker ps`), which
    is what catches `docker run -p`, files outside those paths, and anything started by
    hand. Each finding is a `WARN:` line naming the source.
  - **Does not enforce** anything by default. The default posture is the deployment
    convention "bind published ports to `127.0.0.1`", plus a warning when the host does
    not follow it. Containers started after hardening are not covered at all until the
    module runs again.
  - **Enforces** only with `UFW_DOCKER=1`, which installs the chaifeng/ufw-docker
    DOCKER-USER chain wiring (pinned + checksum-verified, see below).
- `ufw-docker` is fetched from a **pinned commit** and verified against a recorded
  sha256 before it is executed; a mismatch aborts the module. Tracking `master` would
  mean running whatever upstream pushed most recently, as root, on a host being
  hardened. `UFW_DOCKER_REF` / `UFW_DOCKER_SHA256` override the pin, and both must be
  bumped together. A binary already on disk is re-fetched when it does not match the
  pin, so the host converges on the reviewed revision.

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
  - **usb-storage is conditional** (`BLOCK_USB_STORAGE`, default `auto`). The rule lands
    in the initramfs, so blocking it on a host whose root filesystem is on a USB disk
    means the next boot cannot find its root — a real risk on a Raspberry Pi booting from
    a USB SSD, which the arm64 support otherwise invites. `auto` checks whether `/`
    resolves through a USB controller (`/sys/block/<disk>` device path) and skips the
    block with a warning if so. `1` blocks regardless, `0` never blocks.
    `make audit` treats the rare-protocol entries as mandatory and reports usb-storage as
    informational, so a legitimately USB-booted host still passes.
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
- **Exit contract**: `0` when every mandatory control is in the expected state, `1` when
  any is not. That is what makes `make audit` a gate rather than a printout, so CI and
  the tier-3 runner can trust it.
  - Mandatory: SSH password/root login off, no ecdsa host key offered, ufw active,
    fail2ban sshd jail up, unattended-upgrades enabled, journald persistent, core dumps
    off, module blacklist installed, `login.defs UMASK`, the admin's path to root, every
    key in `99-vmt-hardening.conf` that this kernel exposes, and `ssh-audit` finding
    nothing at warn/fail.
  - Informational (`[note]`, never fails): Docker present, auditd outside `TIER=full`.
  - Skipped (`[skip]`, never fails): a sysctl key the running kernel does not expose,
    the whole sysctl sweep under WSL, and tools that are not installed.
  - The Lynis index is informational by default. `LYNIS_MIN=78` makes a drop below the
    recorded baseline fail instead.
- The sysctl sweep is derived from the file 60-sysctl writes, so the two cannot drift.
  It exists because 60-sysctl applies with `sysctl -e`: unknown keys are ignored for
  compatibility with non-generic kernels, which makes end-state verification the only
  place a silently unapplied control can be caught.

## Deliberately skipped (see ASSESSMENT.md §7)
SSH port change · egress filtering · CIS L2 · partitioning · rkhunter · SELinux ·
MOTD legal banners (add if an org ever requires them).
