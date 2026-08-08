# 007 — `60-sysctl`: network + kernel hardening

**Status:** ready
**Depends on:** 001

## Context

Stock cloud images leave ICMP redirects, source routing, and loose rp_filter enabled
(assessment §2.3). Cheap, high-value, CIS Level 1 territory.

## Scope

**In:**
- `/etc/sysctl.d/99-hardening.conf` with the exact keys in [HARDENING.md](../docs/HARDENING.md)
  §60-sysctl (rp_filter, accept/send_redirects off v4+v6, source-route off, log_martians,
  tcp_syncookies, icmp broadcast ignore, kptr_restrict=2, dmesg_restrict, ptrace_scope=1,
  unprivileged_bpf_disabled, fs.protected_sym/hardlinks).
- Apply via `sysctl --system` on a real host; write-file-only on WSL (shared kernel).

**Out:**
- `disable_ipv6` and `unprivileged_userns_clone=0` — both documented as deliberately
  excluded (break dual-stack / rootless containers).

## Acceptance criteria

1. File present with all specified keys; `sysctl --system` applies without error on a
   real host.
2. On a real host, `sysctl net.ipv4.conf.all.rp_filter` = 1 and
   `kernel.yama.ptrace_scope` = 1.
3. WSL run writes the file and prints a `WARN:` that runtime apply is skipped.
4. Idempotent.

## Test plan

- **Tier 2 (WSL):** assert file content; expect the skip-apply warning.
- **Tier 3 (Hetzner):** assert live values via `sysctl` after apply.

## Definition of done

- [ ] Acceptance criteria pass · `make lint` clean · idempotent · `DRY_RUN=1` · STYLE.md clean
