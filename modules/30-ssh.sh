#!/usr/bin/env bash
# 30-ssh — keys-only, no root login, modern algorithms. Lockout-guarded.
# See docs/HARDENING.md §30-ssh and tickets/004.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

ADMIN_USER="${ADMIN_USER:-admin}"
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-0}"
guard=/run/vm-template.lockout-ok

# --- refuse to lock the operator out -----------------------------------------
# 00-preflight drops the guard file only when key access is proven (or forced).
if [[ ! -f $guard ]]; then
  die "lockout guard not set — run 00-preflight first, add an authorized_key, or set FORCE_LOCKOUT_OK=1. Refusing to disable password auth."
fi

allow_line=""
[[ $SSH_ALLOW_USERS == 1 ]] && allow_line="AllowUsers ${ADMIN_USER}"

# Drop-in only; never edit the shipped sshd_config. Algorithms below are the
# modern set ssh-audit accepts on current OpenSSH; older daemons ignore unknown
# names, and `sshd -t` gates the reload regardless.
conf=/etc/ssh/sshd_config.d/10-hardening.conf
candidate="$(mktemp)"
cat >"$candidate" <<EOF
# Managed by vm-template (30-ssh). Do not edit by hand.
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
PermitEmptyPasswords no
# Offer only strong host keys — this stops sshd presenting the ecdsa (nistp256)
# host key that ssh-audit flags. ed25519 + rsa host keys exist on stock images.
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
TCPKeepAlive no
Compression no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
${allow_line}
EOF

# --- install transactionally --------------------------------------------------
# A drop-in that `sshd -t` rejects must not survive on disk: the running daemon
# would keep working, and the next reboot or `systemctl restart ssh` would fail
# to start sshd at all. So: back up, write, validate the effective config, and
# restore on failure. `sshd -t` parses the real include chain, which is why the
# candidate is validated in place rather than on its own.
conf_changed=0
backup=""
had_conf=0
[[ -f $conf ]] && had_conf=1

if [[ $had_conf == 1 ]] && cmp -s "$candidate" "$conf"; then
  log_ok "$conf unchanged"
  rm -f "$candidate"
elif [[ $DRY_RUN == 1 ]]; then
  log_changed "$conf (dry-run, not written)"
  rm -f "$candidate"
else
  conf_changed=1
  if [[ $had_conf == 1 ]]; then
    backup="$(mktemp)"
    cp -p "$conf" "$backup"
  fi
  install -D -m 0644 "$candidate" "$conf"
  rm -f "$candidate"
  log_changed "$conf"
fi

rollback() {
  if [[ $had_conf == 1 && -n $backup ]]; then
    cp -p "$backup" "$conf"
    log_warn "restored the previous $conf"
  else
    rm -f "$conf"
    log_warn "removed $conf (there was no previous version)"
  fi
  sshd -t >/dev/null 2>&1 ||
    log_warn "sshd -t still fails after rollback — the pre-existing sshd config is broken"
}

# --- validate, then reload (never restart — reload keeps live sessions) ------
if [[ $DRY_RUN == 1 ]]; then
  log_ok "sshd config test + reload (dry-run)"
  exit 0
fi

# sshd -t needs the privilege-separation dir; a fresh boot or an openssh
# upgrade can leave it absent, which fails the test with a misleading error.
[[ -d /run/sshd ]] || mkdir -p /run/sshd

if ! sshd -t 2>/tmp/vmt-sshd-test.err; then
  log_warn "sshd -t FAILED — rolling back, config not activated:"
  cat /tmp/vmt-sshd-test.err >&2
  [[ $conf_changed == 1 ]] && rollback
  die "sshd rejected the hardening drop-in"
fi
log_ok "sshd -t passed"
[[ -n $backup ]] && rm -f "$backup"

if is_wsl; then
  log_warn "WSL: skipping sshd reload (not representative)"
elif systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
  # Reload every run so the daemon converges even if an earlier run failed here,
  # but only report a change when the config on disk actually changed.
  if [[ $conf_changed == 1 ]]; then
    log_changed "sshd reloaded"
  else
    log_ok "sshd config already applied"
  fi
else
  log_warn "could not reload the ssh service — the config is on disk but may not be live"
fi
