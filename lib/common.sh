#!/usr/bin/env bash
# Shared helpers for vm-template modules. Source at the top of every module:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"

log_ok()      { printf 'OK:      %s\n' "$*"; }
log_changed() { printf 'CHANGED: %s\n' "$*"; }
log_warn()    { printf 'WARN:    %s\n' "$*" >&2; }
die()         { printf 'FATAL:   %s\n' "$*" >&2; exit 1; }

# os_id / os_codename from /etc/os-release (ubuntu|debian|kali)
# shellcheck disable=SC1091
source /etc/os-release
os_id="${ID:-unknown}"
os_codename="${VERSION_CODENAME:-${DEBIAN_CODENAME:-unknown}}"

require_root() { [[ $EUID -eq 0 ]] || die "run as root (or via sudo)"; }

require_distro() { # usage: require_distro ubuntu debian kali
  local d
  for d in "$@"; do [[ $os_id == "$d" ]] && return 0; done
  die "module does not support distro '$os_id' (supported: $*)"
}

# Write $2 (stdin if '-') to file $1 only if content differs; reports OK/CHANGED.
install_file() {
  local dst="$1" src="$2" tmp
  tmp="$(mktemp)"
  if [[ $src == - ]]; then cat > "$tmp"; else cp "$src" "$tmp"; fi
  if [[ -f $dst ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"; log_ok "$dst unchanged"
  else
    if [[ $DRY_RUN == 1 ]]; then
      log_changed "$dst (dry-run, not written)"; rm -f "$tmp"
    else
      install -m "${3:-0644}" "$tmp" "$dst"; rm -f "$tmp"; log_changed "$dst"
    fi
  fi
}

apt_install() { # idempotent package install
  local missing=()
  local p
  for p in "$@"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
  if ((${#missing[@]} == 0)); then
    log_ok "packages present: $*"
  elif [[ $DRY_RUN == 1 ]]; then
    log_changed "would install: ${missing[*]} (dry-run)"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    log_changed "installed: ${missing[*]}"
  fi
}
