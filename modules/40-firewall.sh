#!/usr/bin/env bash
# 40-firewall — ufw default-deny + Docker/ufw bypass handling.
# See docs/HARDENING.md §40-firewall and tickets/005.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

SSH_PORT="${SSH_PORT:-22}"
EXTRA_PORTS="${EXTRA_PORTS:-80/tcp 443/tcp}"
UFW_DOCKER="${UFW_DOCKER:-0}"
# ufw-docker is fetched from GitHub and run as root, so it is pinned to a tagged commit
# and checksum-verified. `master` is a moving target: whatever upstream pushed most
# recently would execute here with full privileges, on a host being hardened. Bump the
# ref and the hash together, after reading the diff.
UFW_DOCKER_REF="${UFW_DOCKER_REF:-78366b6afe6e566cd53f7e55341889c2e3c863e7}" # tag 251123
UFW_DOCKER_SHA256="${UFW_DOCKER_SHA256:-c3e5f0bf6061a3a2e7d7ac06abc80665707d2f4c91e90d76f22e4168863fb472}"

apt_install ufw

# --- base policy (idempotent: ufw allow is a no-op if the rule exists) -------
ufw_do() { if [[ $DRY_RUN == 1 ]]; then log_changed "ufw $* (dry-run)"; else ufw "$@" >/dev/null; fi; }

ufw_do default deny incoming
ufw_do default allow outgoing
ufw_do allow "${SSH_PORT}/tcp"
for p in $EXTRA_PORTS; do ufw_do allow "$p"; done
log_ok "ufw rules declared (ssh:${SSH_PORT}, extra: ${EXTRA_PORTS})"

if [[ $DRY_RUN != 1 ]]; then
  if is_wsl; then
    log_warn "WSL: not enabling ufw (shared kernel; not representative)"
  else
    ufw --force enable >/dev/null
    log_ok "ufw enabled"
  fi
fi

# --- Docker/ufw bypass: containers published on 0.0.0.0 skip ufw entirely ----
# Warn on any compose port that is not loopback-bound. See DELIVERY/HARDENING notes.
shopt -s nullglob
for cf in /opt/*/docker-compose.y*ml /opt/*/*/docker-compose.y*ml; do
  while IFS= read -r line; do
    # a published mapping like "8080:8080" or "0.0.0.0:8080:8080" (not 127.0.0.1:)
    if [[ $line =~ ^[[:space:]]*-[[:space:]]*\"?([0-9.]+:)?[0-9]+:[0-9]+ ]] \
      && [[ ! $line =~ 127\.0\.0\.1: ]]; then
      log_warn "compose $cf publishes a non-loopback port: ${line#"${line%%[![:space:]]*}"} — ufw does NOT gate this"
    fi
  done < <(grep -A20 -E '^\s*ports:' "$cf" 2>/dev/null || true)
done
shopt -u nullglob

if [[ $UFW_DOCKER == 1 ]]; then
  # The container IP rotates on restart, so static after.rules rot — use the tool.
  ufw_docker_bin=/usr/local/bin/ufw-docker
  ufw_docker_url="https://raw.githubusercontent.com/chaifeng/ufw-docker/${UFW_DOCKER_REF}/ufw-docker"
  sha_of() { sha256sum "$1" | awk '{print $1}'; }

  if [[ -f $ufw_docker_bin ]] && [[ "$(sha_of "$ufw_docker_bin")" == "$UFW_DOCKER_SHA256" ]]; then
    log_ok "ufw-docker present at the pinned revision (${UFW_DOCKER_REF:0:12})"
  elif [[ $DRY_RUN == 1 ]]; then
    log_changed "would fetch ufw-docker ${UFW_DOCKER_REF:0:12}, verify sha256, wire DOCKER-USER (dry-run)"
  else
    apt_install curl
    tmp="$(mktemp)"
    if ! curl -fsSL "$ufw_docker_url" -o "$tmp"; then
      rm -f "$tmp"
      die "could not download ufw-docker from $ufw_docker_url"
    fi
    got="$(sha_of "$tmp")"
    if [[ $got != "$UFW_DOCKER_SHA256" ]]; then
      rm -f "$tmp"
      die "ufw-docker checksum mismatch (want $UFW_DOCKER_SHA256, got $got) — refusing to run it as root"
    fi
    install -m 0755 "$tmp" "$ufw_docker_bin"
    rm -f "$tmp"
    "$ufw_docker_bin" install >/dev/null
    systemctl reload ufw >/dev/null 2>&1 || true
    log_changed "installed ufw-docker ${UFW_DOCKER_REF:0:12} + DOCKER-USER wiring"
  fi
else
  log_ok "UFW_DOCKER not requested (bind container ports to 127.0.0.1 instead)"
fi
