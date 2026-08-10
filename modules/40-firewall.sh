#!/usr/bin/env bash
# 40-firewall — ufw default-deny + Docker/ufw bypass handling.
# See docs/HARDENING.md §40-firewall and tickets/005.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

SSH_PORT="${SSH_PORT:-22}"
# Only SSH is opened by default. 80/443 came from the web server this baseline grew out
# of; a generic hardened VM should not decide that the host serves HTTP. Web hosts pass
# EXTRA_PORTS="80/tcp 443/tcp" themselves.
EXTRA_PORTS="${EXTRA_PORTS:-}"
UFW_DOCKER="${UFW_DOCKER:-0}"
# ufw-docker is fetched from GitHub and run as root, so it is pinned to a tagged commit
# and checksum-verified. `master` is a moving target: whatever upstream pushed most
# recently would execute here with full privileges, on a host being hardened. Bump the
# ref and the hash together, after reading the diff.
UFW_DOCKER_REF="${UFW_DOCKER_REF:-78366b6afe6e566cd53f7e55341889c2e3c863e7}" # tag 251123
UFW_DOCKER_SHA256="${UFW_DOCKER_SHA256:-c3e5f0bf6061a3a2e7d7ac06abc80665707d2f4c91e90d76f22e4168863fb472}"
# Where to look for compose files declaring a publish. The runtime check below is the
# one that catches everything actually running; this only reads intent from disk.
# Depth 4 covers /opt/<app>/, /opt/<stack>/<app>/ and /home/<user>/<project>/<app>/
# without walking whole home directories. Anything deeper is out of reach by design —
# the running-container pass is what catches it.
COMPOSE_SCAN_DIRS="${COMPOSE_SCAN_DIRS:-/opt /srv /root /home}"
COMPOSE_SCAN_DEPTH="${COMPOSE_SCAN_DEPTH:-4}"

apt_install ufw

# --- base policy (idempotent: ufw allow is a no-op if the rule exists) -------
ufw_do() { if [[ $DRY_RUN == 1 ]]; then log_changed "ufw $* (dry-run)"; else ufw "$@" >/dev/null; fi; }

ufw_do default deny incoming
ufw_do default allow outgoing
ufw_do allow "${SSH_PORT}/tcp"
for p in $EXTRA_PORTS; do ufw_do allow "$p"; done
log_ok "ufw rules declared (ssh:${SSH_PORT}, extra: ${EXTRA_PORTS:-none})"

if [[ $DRY_RUN != 1 ]]; then
  if is_wsl; then
    log_warn "WSL: not enabling ufw (shared kernel; not representative)"
  else
    ufw --force enable >/dev/null
    log_ok "ufw enabled"
  fi
fi

# --- Docker/ufw bypass: containers published on 0.0.0.0 skip ufw entirely ----
# Docker's DNAT rules live in the FORWARD/DOCKER chains, which ufw's INPUT policy never
# sees. This module detects the exposure; it does not close it unless UFW_DOCKER=1.
# Two passes, because neither is sufficient alone:
#   1. compose files under COMPOSE_SCAN_DIRS — intent, readable before anything runs
#   2. containers publishing right now — catches `docker run -p`, compose files outside
#      the scanned paths, and anything started by hand
exposed=0

scan_dirs=()
read -r -a scan_dirs <<<"$COMPOSE_SCAN_DIRS"
existing_dirs=()
for d in "${scan_dirs[@]}"; do [[ -d $d ]] && existing_dirs+=("$d"); done

if ((${#existing_dirs[@]} > 0)); then
  while IFS= read -r cf; do
    [[ -n $cf ]] || continue
    while IFS= read -r line; do
      # a published mapping like "8080:8080" or "0.0.0.0:8080:8080" (not 127.0.0.1:)
      if [[ $line =~ ^[[:space:]]*-[[:space:]]*\"?([0-9.]+:)?[0-9]+:[0-9]+ ]] &&
        [[ ! $line =~ 127\.0\.0\.1: ]]; then
        log_warn "compose $cf publishes a non-loopback port: ${line#"${line%%[![:space:]]*}"} — ufw does NOT gate this"
        exposed=1
      fi
    done < <(grep -A20 -E '^\s*ports:' "$cf" 2>/dev/null || true)
  done < <(find "${existing_dirs[@]}" -maxdepth "$COMPOSE_SCAN_DEPTH" -type f \
    \( -name 'docker-compose.y*ml' -o -name 'compose.y*ml' \) 2>/dev/null || true)
fi

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    log_warn "running container publishes a non-loopback port: $line — ufw does NOT gate this"
    exposed=1
  done < <(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null |
    grep -E '0\.0\.0\.0:|\[::\]:' || true)
fi

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
elif [[ $exposed == 1 ]]; then
  log_warn "ufw is NOT enforcing the published container ports listed above."
  log_warn "Bind them to 127.0.0.1, or set UFW_DOCKER=1 to wire the DOCKER-USER chain."
else
  log_ok "UFW_DOCKER not requested; no non-loopback container publish detected"
fi
