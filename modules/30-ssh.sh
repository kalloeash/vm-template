#!/usr/bin/env bash
# 30-ssh — keys-only, no root login, modern algorithms. Lockout-guarded.
# See docs/HARDENING.md §30-ssh and tickets/004.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

ADMIN_USER="${ADMIN_USER:-admin}"
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-0}"
# Smallest Diffie-Hellman group left in /etc/ssh/moduli. 2048-bit groups are the Logjam
# exposure and what ssh-audit flags; 3071 is the conventional cut (OpenSSH's own moduli
# sizes are 3071/4095/6143/7679/8191).
SSH_MIN_MODULUS="${SSH_MIN_MODULUS:-3071}"
# Rotating a host key breaks every client's known_hosts, so it is never automatic on a
# host that may already be in service. Opt in deliberately.
SSH_REGEN_HOST_KEYS="${SSH_REGEN_HOST_KEYS:-0}"
guard=/run/vm-template.lockout-ok

# --- refuse to lock the operator out -----------------------------------------
# 00-preflight drops the guard file only when key access is proven (or forced).
if [[ ! -f $guard ]]; then
  die "lockout guard not set — run 00-preflight first, add an authorized_key, or set FORCE_LOCKOUT_OK=1. Refusing to disable password auth."
fi

# --- host key and moduli hygiene ---------------------------------------------
# The drop-in below decides which host keys sshd *offers*. This part is about the key
# material and the Diffie-Hellman groups themselves, which the drop-in cannot fix.
#
# Note on counting: no pipeline here stops reading early. `cmd | grep -q` would SIGPIPE
# the writer, and under `set -o pipefail` that fails the assignment and aborts the run.

moduli=/etc/ssh/moduli
if [[ -f $moduli ]]; then
  # field 5 is the modulus size in bits
  weak="$(awk -v min="$SSH_MIN_MODULUS" '!/^#/ && NF >= 5 && $5 < min' "$moduli" | wc -l)"
  if ((weak == 0)); then
    log_ok "ssh moduli: none below $SSH_MIN_MODULUS bits"
  elif [[ $DRY_RUN == 1 ]]; then
    log_changed "would drop $weak moduli group(s) below $SSH_MIN_MODULUS bits (dry-run)"
  else
    pruned="$(mktemp)"
    awk -v min="$SSH_MIN_MODULUS" '/^#/ || NF < 5 || $5 >= min' "$moduli" >"$pruned"
    # An empty moduli file breaks diffie-hellman-group-exchange-* outright, which is a
    # worse outcome than a 2048-bit group. Only install if usable groups survive.
    remaining="$(awk '!/^#/ && NF >= 5' "$pruned" | wc -l)"
    if ((remaining > 0)); then
      install -m 0644 "$pruned" "$moduli"
      log_changed "dropped $weak moduli group(s) below $SSH_MIN_MODULUS bits ($remaining left)"
    else
      log_warn "not pruning $moduli — nothing would be left above $SSH_MIN_MODULUS bits"
    fi
    rm -f "$pruned"
  fi
fi

# Host key strength. Rotation is deliberately not automatic: it changes the fingerprint
# and every client that has connected before gets a host-key mismatch. On a baseline
# that is applied to hosts already in service, that is an outage, not a hardening step.
rsa_key=/etc/ssh/ssh_host_rsa_key
if [[ -f $rsa_key ]]; then
  rsa_bits="$(ssh-keygen -lf "$rsa_key" 2>/dev/null | awk '{print $1}')"
  if [[ ${rsa_bits:-0} -ge 3072 ]]; then
    log_ok "rsa host key is ${rsa_bits} bits"
  elif [[ $SSH_REGEN_HOST_KEYS == 1 ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      log_changed "would regenerate the ${rsa_bits}-bit rsa host key at 4096 bits (dry-run)"
    else
      log_warn "regenerating the ${rsa_bits}-bit rsa host key — every client will see a host-key change"
      rm -f "$rsa_key" "$rsa_key.pub"
      ssh-keygen -q -t rsa -b 4096 -f "$rsa_key" -N '' -C ''
      log_changed "regenerated the rsa host key at 4096 bits"
    fi
  else
    log_warn "rsa host key is only ${rsa_bits} bits — set SSH_REGEN_HOST_KEYS=1 to replace it (clients will see a host-key change)"
  fi
fi

# ecdsa key material is left alone on purpose: the drop-in stops sshd offering it, and
# deleting it buys nothing durable, because ssh-keygen -A regenerates missing host keys
# the next time the service starts.
if [[ -f /etc/ssh/ssh_host_ecdsa_key ]]; then
  log_ok "ecdsa host key present but not offered (HostKey pins ed25519 + rsa)"
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
  cat /tmp/vmt-sshd-test.err >&2
  if [[ $conf_changed == 1 ]]; then
    log_warn "sshd -t FAILED after writing $conf — rolling back, config not activated"
    rollback
    die "sshd rejected the hardening drop-in"
  fi
  # Our file was already on disk unchanged, so it is not what sshd is objecting to.
  # Saying otherwise sends whoever reads this at the wrong file.
  log_warn "sshd -t FAILED but $conf was unchanged — the problem is elsewhere in the config"
  die "sshd config is invalid; $conf left as it was"
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
