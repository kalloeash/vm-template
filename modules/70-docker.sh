#!/usr/bin/env bash
# 70-docker — official repo install + daemon.json log caps and hardening.
# See docs/HARDENING.md §70-docker and tickets/008.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_root
require_distro ubuntu debian kali

DOCKER_GROUP_USER="${DOCKER_GROUP_USER:-}"

# Kali is Debian-derived but not in Docker's repo matrix — map it to Debian stable.
repo_id="$os_id"
repo_codename="$os_codename"
if [[ $os_id == kali ]]; then
  repo_id="debian"
  repo_codename="bookworm"
  log_warn "Kali detected: using Docker's debian/$repo_codename repo"
fi

if command -v docker >/dev/null && docker --version >/dev/null 2>&1; then
  log_ok "docker already installed"
elif [[ $DRY_RUN == 1 ]]; then
  log_changed "would add Docker apt repo + install engine (dry-run)"
else
  apt_install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL "https://download.docker.com/linux/$repo_id/gpg" |
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  arch="$(dpkg --print-architecture)"
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$repo_id $repo_codename stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  log_changed "docker engine installed"
fi

is_wsl || ensure_service_enabled docker

# --- daemon.json: cap logs (the classic disk-fill outage), harden defaults ---
# Merge with any existing file rather than clobbering it.
daemon=/etc/docker/daemon.json
desired='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "no-new-privileges": true
}'
# The candidate goes to a temp file first: piping into install_file would run it in a
# subshell, and VMT_FILE_CHANGED (which decides the restart below) would be lost.
candidate="$(mktemp)"
if [[ -f $daemon ]] && command -v python3 >/dev/null; then
  python3 - "$daemon" >"$candidate" <<PY
import json,sys
cur=json.load(open(sys.argv[1]))
cur.setdefault("log-driver","json-file")
cur.setdefault("log-opts",{}).update({"max-size":"10m","max-file":"3"})
cur["live-restore"]=True; cur["no-new-privileges"]=True
print(json.dumps(cur,indent=2))
PY
else
  printf '%s\n' "$desired" >"$candidate"
fi
install_file "$daemon" "$candidate"
daemon_changed=$VMT_FILE_CHANGED
rm -f "$candidate"

# Restart only when daemon.json changed. An unconditional restart bounced every
# container on every run and reported a change that had not happened.
if [[ $daemon_changed == 1 && $DRY_RUN != 1 ]] && ! is_wsl &&
  systemctl is-active --quiet docker 2>/dev/null; then
  if systemctl restart docker >/dev/null 2>&1; then
    log_changed "docker restarted (daemon.json changed)"
  else
    log_warn "docker restart failed — daemon.json is on disk but not live"
  fi
fi

# --- docker group membership is root-equivalent: opt-in only -----------------
if [[ -n $DOCKER_GROUP_USER ]]; then
  log_warn "adding $DOCKER_GROUP_USER to docker group — this is root-equivalent access"
  run "add $DOCKER_GROUP_USER to docker group" usermod -aG docker "$DOCKER_GROUP_USER"
fi
