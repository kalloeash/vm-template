#!/usr/bin/env bash
# Shared helpers for vm-template modules. Source at the top of every module:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# Contract:
#   log_ok / log_changed / log_warn / die     structured per-step output
#   run "<desc>" cmd args...                   run (or echo under DRY_RUN=1) + count
#   install_file DST SRC|- [MODE]              write only if content differs
#   apt_install PKG...                         idempotent package install
#   require_root / require_distro ID...        guards
#   os_id / os_codename                        from /etc/os-release
#   VMT_CHANGED / VMT_OK                        counters, read by 90-report
# Every module is safe to re-run: a second run should print OK for every step.
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
VMT_CHANGED=0
VMT_OK=0

log_ok() {
  VMT_OK=$((VMT_OK + 1))
  printf 'OK:      %s\n' "$*"
}
log_changed() {
  VMT_CHANGED=$((VMT_CHANGED + 1))
  printf 'CHANGED: %s\n' "$*"
}
log_warn() { printf 'WARN:    %s\n' "$*" >&2; }
die() {
  printf 'FATAL:   %s\n' "$*" >&2
  exit 1
}

# run "<human description>" command args...
# Executes the command, or under DRY_RUN=1 prints it and skips. Counts as CHANGED.
run() {
  local desc="$1"
  shift
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "$desc (dry-run: $*)"
    return 0
  fi
  "$@"
  log_changed "$desc"
}

# os_id / os_codename from /etc/os-release (ubuntu|debian|kali)
# os_id/os_codename are consumed by the modules that source this file (SC2034 off).
# shellcheck disable=SC2034
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-unknown}"
  os_codename="${VERSION_CODENAME:-unknown}"
else
  os_id="unknown"
  os_codename="unknown"
fi

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root (or via sudo)"; }

require_distro() { # usage: require_distro ubuntu debian kali
  local d
  for d in "$@"; do [[ $os_id == "$d" ]] && return 0; done
  die "module does not support distro '$os_id' (supported: $*)"
}

# Write $2 (a file, or stdin when '-') to $1 only if content differs.
install_file() {
  local dst="$1" src="$2" mode="${3:-0644}" tmp
  tmp="$(mktemp)"
  if [[ $src == - ]]; then cat >"$tmp"; else cp "$src" "$tmp"; fi
  if [[ -f $dst ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    log_ok "$dst unchanged"
    return 0
  fi
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "$dst (dry-run, not written)"
    rm -f "$tmp"
    return 0
  fi
  install -D -m "$mode" "$tmp" "$dst"
  rm -f "$tmp"
  log_changed "$dst"
}

apt_install() { # idempotent: only installs packages not already present
  local missing=() p
  for p in "$@"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
  if ((${#missing[@]} == 0)); then
    log_ok "packages present: $*"
    return 0
  fi
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "would install: ${missing[*]} (dry-run)"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null
  log_changed "installed: ${missing[*]}"
}

# True when running under WSL (kernel-level changes are not representative there).
is_wsl() { [[ -f /proc/sys/kernel/osrelease ]] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; }
