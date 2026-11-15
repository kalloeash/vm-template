#!/usr/bin/env bash
# Shared helpers for vm-template modules. Source at the top of every module:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# Contract:
#   log_ok / log_changed / log_warn / die     structured per-step output
#   run "<desc>" cmd args...                   run (or echo under DRY_RUN=1) + count
#   install_file DST SRC|- [MODE]              write only if content differs
#   VMT_FILE_CHANGED                           set by install_file: 1 = it wrote
#   VMT_SHOW_CONTENT=1                         with DRY_RUN=1, print what would be written
#   ensure_service_enabled UNIT                enable --now only when not already so
#   apt_install PKG...                         idempotent package install
#   require_root / require_distro ID...        guards
#   os_id / os_codename                        from /etc/os-release
#   VMT_CHANGED / VMT_OK                        counters, read by 90-report
#   module_skipped NAME / skip_if_requested NAME   SKIP_MODULES handling
#   validate_* / glob_to_regex                   input checks for the optional knobs
# Every module is safe to re-run: a second run should print OK for every step.
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
VMT_CHANGED=0
VMT_OK=0
# Result of the most recent install_file call, so a caller can restart a service only
# when its config actually changed. Read it right after the call — it is overwritten by
# the next one, and it stays 0 unless install_file has run.
# Read by the modules that source this file, not here (SC2034 off).
# shellcheck disable=SC2034
VMT_FILE_CHANGED=0

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
  VMT_FILE_CHANGED=0
  tmp="$(mktemp)"
  if [[ $src == - ]]; then cat >"$tmp"; else cp "$src" "$tmp"; fi
  if [[ -f $dst ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    log_ok "$dst unchanged"
    return 0
  fi
  # shellcheck disable=SC2034
  VMT_FILE_CHANGED=1
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "$dst (dry-run, not written)"
    # Tests read the rendered content this way; nothing is written either way.
    if [[ ${VMT_SHOW_CONTENT:-0} == 1 ]]; then sed 's/^/    | /' "$tmp"; fi
    rm -f "$tmp"
    return 0
  fi
  install -D -m "$mode" "$tmp" "$dst"
  rm -f "$tmp"
  log_changed "$dst"
}

# Enable + start a unit only when it is not already enabled and running, so a
# converged host reports OK instead of a change that did not happen.
ensure_service_enabled() {
  local unit="$1" en=0 act=0
  systemctl is-enabled --quiet "$unit" 2>/dev/null && en=1
  systemctl is-active --quiet "$unit" 2>/dev/null && act=1
  if ((en == 1 && act == 1)); then
    log_ok "$unit enabled and running"
    return 0
  fi
  if [[ $DRY_RUN == 1 ]]; then
    log_changed "would enable --now $unit (dry-run)"
    return 0
  fi
  if systemctl enable --now "$unit" >/dev/null 2>&1; then
    log_changed "enabled $unit"
  else
    log_warn "could not enable $unit"
  fi
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

# --- SKIP_MODULES -------------------------------------------------------------
# Space-separated short module names (the part after the number: "docker" for
# 70-docker). 00-preflight and 90-report always run, so they are not skippable.
VMT_KNOWN_MODULES="update user ssh firewall fail2ban sysctl hardening docker auditd"
SKIP_MODULES="${SKIP_MODULES:-}"

validate_skip_modules() {
  local m k found
  for m in $SKIP_MODULES; do
    found=0
    for k in $VMT_KNOWN_MODULES; do [[ $m == "$k" ]] && found=1; done
    ((found == 1)) || die "SKIP_MODULES: unknown module '$m' (known: $VMT_KNOWN_MODULES)"
  done
}

module_skipped() { # module_skipped docker
  local m
  for m in $SKIP_MODULES; do [[ $m == "$1" ]] && return 0; done
  return 1
}

# First line of a skippable module, after its guards: exit cleanly when the caller asked
# for it to be skipped. Validates the whole list so a typo fails here as well.
skip_if_requested() {
  validate_skip_modules
  if module_skipped "$1"; then
    log_ok "$1 skipped (SKIP_MODULES)"
    exit 0
  fi
}

# --- input validation for optional knobs ---------------------------------------
# One address or CIDR, IPv4 or IPv6. Strict enough to keep a typo out of ufw and
# fail2ban config, not a full parser.
is_ip_or_cidr() {
  local a="$1" ip pfx="" has_pfx=0
  ip="${a%%/*}"
  if [[ $a == */* ]]; then
    has_pfx=1
    pfx="${a#*/}"
  fi
  if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local o
    for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
    ((has_pfx == 0)) || { [[ $pfx =~ ^[0-9]{1,2}$ ]] && ((10#$pfx <= 32)); }
  elif [[ $ip =~ ^[0-9a-fA-F:]+$ && $ip == *:*:* ]]; then
    ((has_pfx == 0)) || { [[ $pfx =~ ^[0-9]{1,3}$ ]] && ((10#$pfx <= 128)); }
  else
    return 1
  fi
}

validate_address_list() { # validate_address_list VARNAME "value"
  local name="$1" list="$2" a
  for a in $list; do
    is_ip_or_cidr "$a" || die "$name: '$a' is not an IPv4/IPv6 address or CIDR"
  done
}

validate_flag01() { # validate_flag01 VARNAME "value"
  [[ $2 == 0 || $2 == 1 ]] || die "$1 must be 0 or 1 (got '$2')"
}

# Journald storage mode and the size cap that applies to volatile storage.
JOURNAL_STORAGE="${JOURNAL_STORAGE:-persistent}"
JOURNAL_VOLATILE_MAX_USE="${JOURNAL_VOLATILE_MAX_USE:-32M}"
# Paths are variables only so the tests can point them at a scratch directory.
VMT_JOURNALD_CONF="${VMT_JOURNALD_CONF:-/etc/systemd/journald.conf}"
VMT_JOURNALD_DROPIN="${VMT_JOURNALD_DROPIN:-/etc/systemd/journald.conf.d/50-vmt-volatile.conf}"
validate_journal() {
  case "$JOURNAL_STORAGE" in
    persistent | volatile) ;;
    *) die "JOURNAL_STORAGE must be persistent or volatile (got '$JOURNAL_STORAGE')" ;;
  esac
  [[ $JOURNAL_VOLATILE_MAX_USE =~ ^[1-9][0-9]*[KMGT]?$ ]] ||
    die "JOURNAL_VOLATILE_MAX_USE must be a size like 32M (got '$JOURNAL_VOLATILE_MAX_USE')"
}

# Turn space-separated shell globs into the anchored regexes that
# Unattended-Upgrade::Package-Blacklist expects (Python regexes, matched from the start
# of the package name; unattended-upgrade adds the leading ^ itself). Only characters
# that occur in Debian package names are accepted. No backslashes are emitted, so the
# result needs no escaping inside an apt.conf string.
glob_to_regex() { # glob_to_regex "linux-image-* raspi-firmware"  -> one regex per line
  local g r i c
  for g in $1; do
    [[ $g =~ ^[a-z0-9][a-z0-9.+*?:-]*$ ]] ||
      die "UPGRADE_HOLD_PACKAGES: '$g' is not a package name pattern (a-z 0-9 . + - : * ?)"
    r=""
    for ((i = 0; i < ${#g}; i++)); do
      c="${g:i:1}"
      case "$c" in
        '*') r+='.*' ;;
        '?') r+='.' ;;
        '.') r+='[.]' ;;
        '+') r+='[+]' ;;
        *) r+="$c" ;;
      esac
    done
    printf '%s$\n' "$r"
  done
}
