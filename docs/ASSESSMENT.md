# Assessment — generalized VM baseline

Written 2026-08-08, based on: the encryptedlinkvm QUICKSTART (the manual process this
template generalizes), the encryptedlink production compose/nginx configs, and the web
research listed at the bottom.

## 1. What you do today (from encryptedlinkvm QUICKSTART)

| Step | Quality |
|---|---|
| `apt update && upgrade` | ✅ fine |
| ufw: default deny in / allow out, allow 22+80+443 | ✅ fine |
| fail2ban sshd jail, maxretry 3, incremental bans to 5w | ✅ good — better than most guides |
| Docker from the official apt repo (not snap/distro) | ✅ correct choice |
| unattended-upgrades + `52autoreboot.conf` (also `-updates`, 04:00 reboot, kernel cleanup) | ✅ genuinely good; most checklists stop at `-security` |
| certbot --nginx with auto-renew dry-run | ✅ fine |
| Container ports bound to `127.0.0.1` with the Docker/UFW-bypass rationale documented | ✅ excellent — this is the #1 Docker footgun and you already dodge it |
| Hetzner platform backups + restore-test backlog item + KEY_ESCROW.md | ✅ fine |

## 2. What's missing (the honest gap list)

Ordered by how much it matters:

1. **SSH is never actually hardened.** The QUICKSTART *says* "key-based authentication
   recommended" and then never touches `sshd_config`. If the provider image ships with
   `PasswordAuthentication yes` (many do), the box accepts password brute-force forever —
   fail2ban mitigates but doesn't eliminate. Needed: `PasswordAuthentication no`,
   `PermitRootLogin no`, `KbdInteractiveAuthentication no`, `MaxAuthTries 3`,
   `ClientAliveInterval 300` + `ClientAliveCountMax 2`, modern
   `KexAlgorithms`/`Ciphers`/`MACs` (curve25519, aes-gcm, chacha20 — verified by
   `ssh-audit`), and optionally `AllowUsers <admin>`. **This is the single biggest gap.**
2. **Everything runs as root.** Every `scp`/`ssh` example in the QUICKSTART targets
   `root@`. Needed: a `20-user` module that creates an admin user with sudo and copies
   `authorized_keys`, after which root login is disabled entirely.
3. **No sysctl hardening.** Stock cloud images leave ICMP redirects, source routing, and
   loose rp_filter enabled. A small `/etc/sysctl.d/99-hardening.conf` covers: rp_filter=1,
   accept_redirects=0, send_redirects=0, accept_source_route=0, log_martians=1,
   tcp_syncookies=1, and kernel-side `kptr_restrict=2`, `dmesg_restrict=1`,
   `ptrace_scope=1`, `unprivileged_bpf_disabled=1`. Cheap, high value, CIS L1 territory.
3. **Docker daemon defaults are unbounded.** No `daemon.json` means unlimited json-file
   logs — a chatty container **fills the disk** (this is the most common self-inflicted
   VPS outage). Needed: `log-driver: json-file` with `max-size`/`max-file`,
   `live-restore: true`, `no-new-privileges: true`.
4. **No audit trail.** Nothing records privileged actions. `auditd` with a small CIS-ish
   ruleset (execve by root, sudoers changes, sshd_config changes) is the standard answer;
   journald persistence (`Storage=persistent`) is the minimum.
5. **needrestart absent.** unattended-upgrades reboots for kernel/libc, but daemons keep
   running against deleted libraries after other lib upgrades. `needrestart` in automatic
   mode closes that.
6. **No file-integrity or minimal-package pass.** Optional tier: AIDE is cheap insurance;
   removing snapd/unused packages shrinks surface. Low priority for a single-purpose VM.
7. **Time sync unverified.** Ubuntu's systemd-timesyncd is fine, but the template should
   assert it's active (cert validation and fail2ban windows depend on sane clocks).

## 3. Mistakes in the current process (yes, you asked)

1. **`docker login ghcr.io -u kalloeash -p YOUR_GITHUB_PAT`** — puts the PAT in shell
   history and the process list. Use `--password-stdin`. Same for the generated secrets
   `echo`'d to the terminal (scrollback + history); generate straight into the file.
2. **`cp jail.conf jail.local`** — copying the entire fail2ban config as an override is
   an upstream anti-pattern (makes package upgrades noisy/conflicting). Your
   `jail.d/sshd.local` snippet is the right mechanism; the full copy should go.
3. **`newgrp docker`** only affects the current shell — in a script it does nothing
   useful. Also worth an honest note: docker-group membership **is root-equivalence**;
   fine for a solo admin who is root anyway, but the doc should say so.
4. **Ordering lockout risk**: any template that disables password auth must first prove
   `authorized_keys` works — the module needs a hard guard (refuse to disable password
   auth if the connecting session can't be key-authenticated / authorized_keys is empty).
   Your manual process survives because a human is careful; scripts must encode it.
5. QUICKSTART troubleshooting says compose **healthchecks were removed** to fix a startup
   issue — that traded away self-healing signal. Worth revisiting separately (the stack
   compose in encryptedlinkapi has working healthchecks since the 127.0.0.1 fix).

## 4. Tooling decision

**Chosen: Bash modules + Makefile + Lynis/ssh-audit for verification.**

- *Why not Ansible (dev-sec/ansible-lockdown)?* Those collections are excellent and
  battle-tested — for **fleets**. They bring a control-node dependency, YAML indirection,
  and (for ansible-lockdown) compliance paperwork you don't need on 1–3 personal VMs. If
  the host count grows, migrate: the module boundaries here map ~1:1 onto dev-sec roles.
- *Why Makefile?* You asked, and it's right: `make harden` / `make ssh` / `make audit`
  gives named entry points, dependency ordering, and per-module reruns for free, with
  zero runtime deps beyond `make` (in every distro's base tooling).
- *Verification is a separate tool on purpose*: **Lynis** gives an independent hardening
  index (a number you can watch go up, and regression-test), **ssh-audit** validates the
  sshd algorithm set against current cryptographic advice. We don't grade our own
  homework.
- *Lint*: shellcheck + shfmt via pre-commit (same pre-commit pattern as your other repos).

## 5. Distro compatibility strategy

Target = **Debian family only**: Ubuntu 22.04/24.04 LTS (primary), Debian 12/13
(supported), **Kali (best-effort tier)**. Everything uses apt + systemd + ufw, so one
code path covers all three; `lib/common.sh` reads `/etc/os-release` and each module
declares which IDs it supports.

Kali caveats to encode: rolling release (no `-security` pocket — the unattended-upgrades
origins differ), default `kali` user already exists (20-user adapts), and a pentest box
often *wants* tools a server baseline would remove — so the minimal-packages module is
skipped on Kali by default. RHEL-family is explicitly out (dnf/firewalld double every
module for zero current need).

### Raspberry Pi 4B / arm64

Ubuntu Server 24.04 ships an official Pi image
(`ubuntu-24.04-preinstalled-server-arm64+raspi.img.xz`) with the same package set as
x86_64, so the baseline targets it directly. Verified for arm64 (2026-08-09): arch
detection returns `arm64`, every installed package has an arm64 candidate, and Docker's
apt repo resolves `docker-ce` for arm64 (checked in a QEMU arm64 Ubuntu 24.04 container —
Hetzner ARM stock was unavailable at test time).

Pi-specific points, and how they are handled:
- **linux-raspi kernel** may not expose every hardening sysctl key → 60-sysctl uses
  `sysctl -e` to apply what exists and skip the rest instead of aborting.
- **No GRUB** on the Pi (its own bootloader) → the baseline never touches GRUB, so the
  one boot-loader Lynis suggestion is moot there anyway.
- **cloud-init** on the Pi image reads `user-data`/`network-config` from the boot FAT
  partition, not a cloud datasource → delivery path A (post-boot `make harden`) is the
  reliable route on a Pi; path B needs the boot-partition variant.
- Not yet run on physical Pi hardware — the kernel-specific behavior (which exact sysctl
  keys the linux-raspi kernel omits) can only be confirmed on a real board.

## 6. Test strategy (summary — full detail in TESTING.md)

Three tiers, cheapest first:

1. **Static (every commit, on Windows/WSL):** shellcheck + shfmt + `bash -n` via
   pre-commit. Catches 80% of script bugs for free.
2. **WSL smoke (minutes):** your existing WSL Ubuntu runs systemd, so most modules
   (ssh config generation, sysctl files, fail2ban, unattended-upgrades policy) can
   execute for real in a throwaway WSL distro (`wsl --import` a clean rootfs, run,
   `wsl --unregister`). Known limits: ufw/kernel sysctls touch the shared WSL kernel —
   assert file state rather than runtime state there.
3. **Real acceptance (per release, ~€0.01):** a **throwaway Hetzner cloud VM** via
   `hcloud` CLI — create CX22 → `make harden` → `make audit` (Lynis index + ssh-audit +
   "second run is all-OK" idempotence check) → delete. This is the same platform as
   production, so it's a true dress rehearsal. Kali/Debian get the same treatment less
   often (Debian image on Hetzner; Kali in a local Hyper-V/VirtualBox VM when relevant).

## 7. What we deliberately do NOT do (documented so it's a decision, not a gap)

- **Change the SSH port** — obscurity, not security; fail2ban + keys-only covers it, and
  a nonstandard port complicates every tool that touches the box.
- **Egress filtering** (`ufw default deny outgoing`) — real security value but constant
  operational friction on a box that pulls images/updates; wrong tradeoff for solo ops.
- **Full CIS Level 2 / partitioning schemes** — can't retrofit partitions onto a cloud
  image; L2 controls (like unprivileged user namespaces off) break Docker.
- **rkhunter/chkrootkit** — noise machines; Lynis covers the useful subset.
- **SELinux** — AppArmor is the Debian-family default; we verify it's enforcing instead.

## 8. Assumptions audit (did we take shortcuts?)

Every load-bearing assumption in this design, checked against the research. `KEEP` = held
up; `FIX` = changed the design; `OWN` = a real tradeoff we accept and now state plainly.

1. **"Post-boot `make harden` is the delivery model."** → **FIX.** Research is consistent
   that applying hardening after boot leaves a day-0 exposure window and that an
   unhardened base image is security debt. The modules now support three delivery paths
   ([DELIVERY.md](DELIVERY.md)): post-boot (day-0 on an existing box), **cloud-init first
   boot** (recommended for new VMs — hardened before reachable), and Packer golden image
   (scale-up endgame). Module code is identical across all three; only invocation differs.
2. **"Bash imperative is fine."** → **OWN.** Imperative scripts handle drift detection and
   partial failure worse than declarative tools. We keep Bash (no control-node dependency
   for 1–3 hosts) but pay the tax deliberately: strict idempotency, `make audit` as the
   drift check declarative tools give for free, and a documented migration to
   dev-sec/Ansible if host count grows. Stated, not hidden.
3. **"Container ports on `127.0.0.1` is enough for the Docker/ufw problem."** → **KEEP.**
   Explicitly endorsed as the best-practice default. Caveat now recorded: a `127.0.0.1`
   bind can affect container-to-container networking, and if a port *must* be published
   publicly, the `ufw-docker` tool is required (not hand-written rules) because container
   IPs change on restart.
4. **"fail2ban sshd jail just works."** → **FIX.** On Ubuntu 24.04 sshd logs to the
   journal, not `/var/log/auth.log`; the jail needs `backend = systemd` (we had this) and
   also `allowipv6 = auto` or it warns/mis-bans on dual-stack. Added to ticket 006.
5. **"Lynis index ≥ some floor."** → **FIX.** Pinned to a realistic target: fresh images
   score ~50–65, a well-hardened server targets **75+**. We record the baseline and
   ratchet, but treat warnings-first as the real signal — and note Lynis is a hardening
   metric, not a vulnerability scan (that is Trivy/nmap/OpenVAS). Updated TESTING.md and
   ticket 009.
6. **"WSL is a faithful test tier."** → **KEEP (already scoped).** WSL shares one kernel,
   so ufw/sysctl runtime is not representative; we already assert file-state only there
   and defer runtime to the Hetzner tier. No change, but re-confirmed as a real limit.
7. **"Debian-family, one code path."** → **KEEP.** apt+systemd+ufw is uniform across
   Ubuntu/Debian/Kali; per-module `require_distro` guards the edges (Kali rolling origins,
   existing `kali` user). RHEL stays out.

## 9. Research sources

- [Ubuntu: CIS benchmark hardening automation for 24.04 (USG)](https://ubuntu.com/blog/hardening-automation-for-cis-benchmarks-now-available-for-ubuntu-24-04-lts)
- [Server hardening checklist for Ubuntu 24.04](https://privatedevops.com/articles/server-hardening-checklist-ubuntu-2404)
- [Linux server hardening 2026: CIS benchmarks & auditd](https://www.decryptiondigest.com/blog/linux-server-security-hardening-guide)
- [SSH hardening best practices (Linuxize)](https://linuxize.com/post/ssh-hardening-best-practices/)
- [Opinionated sshd_config hardening 2025](https://www.msbiro.net/posts/back-to-basics-sshd-hardening/)
- [SSH hardening guide 2026 (byte-guard)](https://blog.byte-guard.net/ssh-hardening-guide/)
- [dev-sec ansible-collection-hardening](https://github.com/dev-sec/ansible-collection-hardening)
- [ansible-lockdown CIS vs dev-sec comparison](https://www.decryptiondigest.com/blog/ansible-security-hardening-automation-cis-benchmark-guide)
- [Lynis + modern Linux hardening approach](https://bigmike.help/en/posts/083/)
- [Why Docker bypasses UFW and how to lock it down](https://dev.to/alanwest/why-docker-bypasses-ufw-and-how-to-actually-lock-it-down-26ep)
- [chaifeng/ufw-docker (DOCKER-USER chain integration)](https://github.com/chaifeng/ufw-docker)
- [Docker published ports ignoring UFW (Baeldung)](https://www.baeldung.com/linux/docker-container-published-port-ignoring-ufw-rules)
- [cloud-init security hardening](https://docs.cloud-init.io/en/latest/explanation/hardening.html)
- [Building a hardened Ubuntu 24.04 image with Packer + cloud-init + OpenSCAP](https://www.hacknwatch.com/posts/packer-hardened-ubuntu-image/)
- [Lynis hardening index explained](https://linux-audit.com/lynis/lynis-hardening-index/)
- [Declarative vs imperative IaC and drift](https://oneuptime.com/blog/post/2026-03-20-declarative-vs-imperative-iac-opentofu/view)
- [fail2ban sshd on systemd-journal hosts (backend=systemd)](https://github.com/fail2ban/fail2ban/issues/3642)
