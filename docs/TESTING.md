# Testing strategy

Three tiers; each catches a different failure class. Cheapest runs most often.

## Tier 1 — static, every commit (Windows, no VM)

```bash
pre-commit run --all-files    # shellcheck, shfmt, bash -n, writing style
make test                     # bats-core unit suite
```

- **shellcheck** catches quoting, word-splitting, and unreachable-code bugs — the bulk of
  real shell defects.
- **shfmt** keeps the modules uniformly formatted (mirrors the prettier/dotnet-format
  role in the other repos).
- **bats** (`tests/`) covers the decisions a module makes before it writes anything: the
  privilege model in 20-user, the port defaults and Docker-bypass detection in
  40-firewall, the SSH lockout refusal, and every helper in `lib/common.sh`.
- CI mirrors all of it — [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs
  lint, pre-commit, the bats suite, and a full `make harden DRY_RUN=1` on every PR.

### How the module tests run without a VM

Modules call `require_root`, and `EUID` cannot be faked. The suite runs them under
`unshare -r` — a user namespace where `EUID` is 0 with no real privilege — together with
`DRY_RUN=1`, so every write goes through `install_file` and does nothing. External
commands that would otherwise make a test depend on the runner (`docker`, `ufw`, `dpkg`)
are stubbed on `PATH`. Tests that need the namespace skip themselves where it is
unavailable rather than failing.

This covers decisions, not effects. Anything that has to actually happen — sshd
reloading, ufw filtering, a rollback surviving a restart — stays tier 3.

## Tier 2 — WSL smoke test (minutes, free, local)

You already run WSL2 with systemd. Test in a **throwaway distro** so the daily one stays
clean:

```powershell
# one-time: download a clean Ubuntu 24.04 WSL rootfs
wsl --install --no-launch Ubuntu-24.04   # or: wsl --import from a saved tarball

# per test run:
wsl --import vmtpl-test C:\wsl\vmtpl-test ubuntu-24.04.tar --version 2
wsl -d vmtpl-test -u root -- bash -c "cd /mnt/c/Projecten/vm-template && make harden && make audit"
wsl --unregister vmtpl-test
```

What WSL **can** validate: module logic, idempotence (run `make harden` twice → second
run must print `OK` for every step), file-state assertions (sshd_config content,
sysctl.d files, fail2ban jails, apt policy), service enablement, user creation.

What WSL **cannot** validate honestly — assert *file state* only, and defer runtime
behavior to Tier 3:

- **ufw / iptables** — WSL shares one kernel across distros; firewall changes are
  side-effectful and not representative.
- **kernel sysctls** — same shared-kernel reason.
- **sshd actually listening / reboot behavior / unattended-upgrades timers firing.**

## Tier 3 — throwaway Hetzner VM (per release, ~€0.01/run)

Same provider as production = a true dress rehearsal, and cheaper than any local
virtualization time-wise:

```bash
hcloud server create --name vmtpl-test --type cx22 --image ubuntu-24.04 --ssh-key <key>
scp -r vm-template root@<ip>:/root/ && ssh root@<ip> "cd vm-template && make harden"
ssh <admin>@<ip> "cd vm-template && make audit && sudo make harden"  # audit + idempotence
hcloud server delete vmtpl-test
```

Acceptance criteria per release:

1. `make harden` completes on a stock image with zero prompts.
2. Second `make harden` run reports `OK` on every step (idempotence).
3. `make audit` passes: **Lynis hardening index ≥ 75** (research floor for a well-hardened
   server; a fresh cloud image scores ~50–65, so the baseline modules should move it 10–20
   points). Record the baseline first, then ratchet. `ssh-audit` reports no failures, all
   our assertions green. **The score is a progress metric, not a grade**: unresolved Lynis
   *warnings* outrank the number, and Lynis is not a vulnerability scan — CVE coverage is
   Trivy's job (built images) plus manual nmap/OpenVAS if ever needed.
4. **Lockout drill**: after hardening, password SSH is refused, root SSH is refused,
   key-based admin SSH works, `sudo` works.
5. Repeat on `debian-13` image (supported tier) each release; Kali (best-effort tier)
   manually in a local VM when its modules change.

## Regression scoring

Keep `docs/lynis-baseline.md` with the hardening-index history per distro (floor 75). A PR
that drops the index below the recorded baseline fails review — same philosophy as the
test-count baselines many projects keep in a CLAUDE.md or similar. Warnings are tracked alongside
the number; a PR may not add a new unaddressed Lynis warning even if the score holds.
