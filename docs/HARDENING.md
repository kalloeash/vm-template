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

## Optional knobs (ticket 016)

Every knob below defaults to today's behaviour. A bad value fails in `00-preflight`
before any module has changed anything, and again in the module that reads it, so a
single `make <module>` is checked too. The Raspberry Pi bundle is in
[RASPBERRY-PI.md](RASPBERRY-PI.md).

- **`SKIP_MODULES`** — space-separated short names (`update user ssh firewall fail2ban
  sysctl hardening docker auditd`). A skipped module prints `OK: <name> skipped
  (SKIP_MODULES)` and does nothing, under `make harden` and under `make <module>`.
  `make audit` reads the same variable and reports the skipped module's controls as
  `[skip] <control> (module <name> skipped: SKIP_MODULES)`. Skips never fail the audit,
  and the end line counts them. Unknown names fail preflight and the audit. Pass the
  same value to `make audit` as to `make harden`. Skipping a module is the caller taking
  that control out of scope: skipping `ssh` or `firewall` leaves the host without them.
  `80-auditd` also owns journald, so skipping it skips the journald setting too.

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
- `UPDATE_SKIP_DIST_UPGRADE=1` skips the immediate `dist-upgrade` (the `apt-get update`
  still runs, and so does everything below). For a device whose first boot must not wait
  on a long upgrade; unattended-upgrades does it later. Default `0`.
- `UPGRADE_HOLD_PACKAGES` (space-separated shell globs, default empty) is written to
  `Unattended-Upgrade::Package-Blacklist` in `52-vmt-autoupgrade`. Globs become anchored
  regexes (`raspi-firmware` -> `raspi-firmware$`, `linux-image-*` -> `linux-image-.*$`),
  because the option takes Python regexes matched from the start of the name. A held
  package is upgraded only by hand.
- **Origins syntax**: on Debian and Kali the origins are written under
  `Unattended-Upgrade::Origins-Pattern` (`origin=Debian,codename=...` strings); that key
  is the only one that takes them. Under `Allowed-Origins` they make `unattended-upgrade`
  stop with "Unable to parse Unattended-Upgrade::Allowed-Origins". Ubuntu keeps the
  legacy `Allowed-Origins` form (`${distro_id}:${distro_codename}-security`). The Debian
  security suite is `<codename>-security`, so the pattern is
  `codename=${distro_codename}-security,label=Debian-Security`.
- `UPGRADE_REMOVE_UNUSED_KERNELS` (`1` default, `0`) sets
  `Remove-Unused-Kernel-Packages`. Set `0` on a host that holds kernel packages back:
  the previous kernel is then the only rollback.
- **Raspberry Pi archive**: when `apt-cache policy` or the apt source files show
  `archive.raspberrypi.com`, a separate drop-in `53-vmt-raspberrypi-origin` adds
  `origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi
  Foundation` to `Origins-Pattern`. The strings are the `Origin`, `Label` and `Codename`
  of the archive's `dists/trixie/Release` (its `Suite` is `stable`, so the codename is
  what matches). The drop-in is removed when the archive is no longer configured.
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
    **Pass it in the environment, not as a make variable** — make expands `$` in
    command-line variables, so `make user ADMIN_PASSWORD_HASH='$6$salt$…'` arrives
    mangled and is rejected. Use `sudo ADMIN_PASSWORD_HASH="$(openssl passwd -6)" make
    user`, or `ADMIN_PASSWORD_HASH_FILE=/path/to/hash`, which also keeps the hash out of
    the process list and shell history.
- `SUDO_NOPASSWD` still overrides the default, but the combination "no usable password
  and `SUDO_NOPASSWD=0`" is rejected with a fatal error rather than shipped: after
  30-ssh disables root login it leaves no path to root.
- `ADMIN_SUDO` (default unset = the behaviour above): `nopasswd` forces the NOPASSWD
  drop-in, `password` forces password-asked sudo (needs a password), `keep` leaves the
  sudo group and every sudoers rule as found, for an image that ships a narrow rule for
  the admin. With `keep` the module only checks that `sudo -l -U <admin>` lists a rule
  (a warning otherwise) and `make audit` reports "can escalate to root" as `[note]`
  instead of a mandatory control, because it cannot judge a custom rule.
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
- **Host keys**: the drop-in pins `HostKey` to the ed25519 and RSA keys sshd is
  configured with (`sshd -T`, read before the drop-in is written) that exist on disk, so
  sshd stops offering the ecdsa (nistp256) key that `ssh-audit` flags. A host whose keys
  live elsewhere keeps them; a path that does not exist is never pinned. `sshd -t`
  passes as long as one host key loads, so after it the module checks every configured
  path and rolls back a drop-in that pins a missing one.
- **Moduli**: `/etc/ssh/moduli` is pruned of Diffie-Hellman groups below
  `SSH_MIN_MODULUS` (default 3071 bits) — the Logjam exposure, and negotiable no matter
  what the drop-in says. If nothing would survive the filter the file is left alone and
  a warning is printed: an empty moduli file breaks
  `diffie-hellman-group-exchange-*` outright, which is worse than the weak group.
  `make audit` asserts the floor afterwards.
- **Host-key strength**: an RSA host key below 3072 bits is reported. Replacing it is
  opt-in (`SSH_REGEN_HOST_KEYS=1`) and never automatic — rotation changes the
  fingerprint, so every client that has connected before gets a host-key mismatch. On a
  baseline applied to hosts already in service that is an outage, not a hardening step.
- **ecdsa key material is left in place** on purpose. The drop-in stops sshd offering
  it, and deleting the files buys nothing durable: `ssh-keygen -A` regenerates missing
  host keys the next time the service starts.
- `sshd -t` gate before reload; **lockout guard consulted before applying**.
- The drop-in is installed transactionally: the previous version is kept, `sshd -t`
  validates the effective config (the include chain, not the fragment alone), and a
  rejected drop-in is restored or removed before the module exits non-zero. A config the
  daemon refuses must never stay on disk — the running sshd survives, but the next
  reboot or `systemctl restart ssh` would not.
- Reload runs on every invocation so the daemon converges after an earlier failed
  reload, but only a real content change reports `CHANGED`.

## 40-firewall
- `SSH_ALLOW_FROM` (space-separated addresses or CIDRs, default empty): when set, ufw
  allows the SSH port only from those sources (`ufw allow from <src> to any port
  <SSH_PORT> proto tcp`) and an existing open-to-anywhere rule for that port is deleted
  after the new rules are in. The session running the module must come from one of the
  sources or it is cut off. Default: SSH from anywhere, as before.
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
- `FAIL2BAN_IGNOREIP` (space-separated addresses or CIDRs, default empty) adds
  `ignoreip = 127.0.0.1/8 ::1 <addresses>` to the sshd jail. Without it the jail has no
  `ignoreip` line and fail2ban's own default applies.
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
  docker daemon config, privileged execs. journald storage is set in the base tier too:
  `Storage=persistent` by default.
- `JOURNAL_STORAGE=volatile` writes `/etc/systemd/journald.conf.d/50-vmt-volatile.conf`
  (`Storage=volatile`, `RuntimeMaxUse=$JOURNAL_VOLATILE_MAX_USE`, default `32M`) so a
  flash-card device does not wear out under log writes. Logs are lost on reboot. Going
  back to `persistent` removes the drop-in.

## 90-report
- Print per-module status table, `lynis audit system --quick` hardening index,
  `ssh-audit localhost` summary, reboot-required flag.
- **Exit contract**: `0` when every mandatory control is in the expected state, `1` when
  any is not. That is what makes `make audit` a gate rather than a printout, so CI and
  the tier-3 runner can trust it.
  - Mandatory: SSH password/root login off, no ecdsa host key offered, ufw active,
    fail2ban sshd jail up, unattended-upgrades enabled, journald in the configured mode
    (persistent by default; with `JOURNAL_STORAGE=volatile`, the drop-in with the
    configured cap), core dumps
    off, module blacklist installed, `login.defs UMASK`, the admin's path to root, every
    key in `99-vmt-hardening.conf` that this kernel exposes, and `ssh-audit` finding
    nothing at warn/fail.
  - Informational (`[note]`, never fails): Docker present, auditd outside `TIER=full`.
  - Skipped (`[skip]`, never fails): every control of a module named in `SKIP_MODULES`,
    a sysctl key the running kernel does not expose,
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
