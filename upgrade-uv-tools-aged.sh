#!/usr/bin/env bash
# Upgrade uv tools (`uv tool install`) to the newest release at least
# MIN_AGE_DAYS (14) days old. uv applies the window itself (--exclude-newer);
# this script adds what a typed `uv tool upgrade` lacks:
#   - the window on every run, whatever a tool's receipt recorded when it was
#     installed;
#   - a CVE bypass: a tool whose installed version has a known vulnerability
#     (OSV.dev; a uv tool is a PyPI package) upgrades now, past the window;
#   - no downgrades: a tool already newer than the window is left alone.
# No -e: one failed uv/API call counts as a failure and the run goes on to
# the next tool; pipefail and -u still catch mistakes.
set -uo pipefail

# lib/osv-check.sh declares global associative arrays (declare -gA): bash
# 4.2. macOS's /bin/bash is 3.2; `env bash` finds Homebrew's first.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
  echo "$(basename "$0"): needs bash 4.2 or newer, this is $BASH_VERSION (brew install bash)" >&2
  exit 1
fi

usage() {
  cat <<EOT
Usage: $(basename "$0") [--dry-run] [--help]

Upgrade every uv tool to the newest release at least MIN_AGE_DAYS days old.
A tool whose installed version has a known CVE (OSV.dev, PyPI) upgrades to
the newest release at once. A tool already newer than the window is left as
it is.

Options:
  --dry-run    Print what would be upgraded without making any changes.
  --help       Show this help message.

Environment variables:
  MIN_AGE_DAYS  Minimum release age in days (default: 14)
EOT
  exit 0
}

# Shared helpers: output glyphs and the OSV.dev CVE check.
_lib="$(dirname "$0")/lib"
# The linter runs without -x, so it cannot follow these (log.sh is also a
# rendered template).
# shellcheck disable=SC1091
source "$_lib/log.sh"
# shellcheck disable=SC1091
source "$_lib/osv-check.sh"

DRY_RUN=0
for _arg in "$@"; do
  case "$_arg" in
  --dry-run) DRY_RUN=1 ;;
  --help | -h) usage ;;
  esac
done

MIN_AGE_DAYS=${MIN_AGE_DAYS:-14}
if ! [[ $MIN_AGE_DAYS =~ ^[0-9]+$ ]]; then
  _err "MIN_AGE_DAYS must be a whole number of days, not '$MIN_AGE_DAYS'"
  exit 1
fi

_require uv jq

# Summary counters printed at the end of the run.
declare -i _UPGRADED=0 _CVE_BYPASSED=0 _SKIPPED=0 _WARNED=0 _FAILED=0

# The newest release of a PyPI package at least <days> days old, resolved by
# uv itself. --no-config: a user uv.toml must not move the cutoff.
aged_version() {
  local name="$1" days="$2" line
  line=$(printf '%s\n' "$name" |
    uv pip compile --quiet --no-header --no-annotate --no-config \
      --exclude-newer "${days} days" - 2>/dev/null |
    grep -iE "^${name//[-_.]/[-_.]}==") || return 1
  printf '%s\n' "${line#*==}"
}

# True when version $1 sorts after $2.
newer_than() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

# Runs (or previews, under --dry-run) the upgrade within <window>.
do_upgrade() {
  local name="$1" window="$2"
  if ((DRY_RUN)); then
    _info "[dry-run] would run: uv tool upgrade $name --exclude-newer \"$window\"" "   "
    return 0
  fi
  uv tool upgrade "$name" --exclude-newer "$window" </dev/null || {
    _err "$name: upgrade failed"
    ((_FAILED++))
    return 1
  }
}

_title "Checking uv tools (age gate: ${MIN_AGE_DAYS} days)"

# `uv tool list` prints "name vX.Y.Z" per tool, then its entry points
# indented with "- ".
tools=$(uv tool list 2>/dev/null | awk '/^[^- ]/ { sub(/^v/, "", $2); print $1, $2 }') || {
  _err "uv tool list failed"
  exit 1
}
if [[ -z $tools ]]; then
  _ok "no uv tools installed"
  exit 0
fi

while read -r name installed; do
  [[ -z $name ]] && continue

  if [[ -n $installed ]] && osv_vulnerable PyPI "$name" "$installed"; then
    _warn "$name: CVE in installed v${installed} — bypassing age gate"
    do_upgrade "$name" "0 days" && ((_CVE_BYPASSED++))
    continue
  fi

  if ! eligible=$(aged_version "$name" "$MIN_AGE_DAYS"); then
    _warn "$name: could not resolve its newest aged release — skipping"
    ((_WARNED++))
    continue
  fi

  if [[ $eligible == "$installed" ]]; then
    _info "$name: v${installed} is the newest release at least ${MIN_AGE_DAYS} days old"
    ((_SKIPPED++))
  elif newer_than "$installed" "$eligible"; then
    _info "$name: installed v${installed} is newer than the window allows (v${eligible}) — leaving it"
    ((_SKIPPED++))
  else
    _ok "$name: upgrading v${installed} → v${eligible}"
    do_upgrade "$name" "${MIN_AGE_DAYS} days" && ((_UPGRADED++))
  fi
done <<<"$tools"

_title "Summary"
((DRY_RUN)) && _info "dry-run — no changes were made; counts reflect what would have happened"
# shellcheck disable=SC2154 # _c_* colors come from lib/log.sh
{
  _count "Upgraded (age-gated):" "${_UPGRADED}" "$_c_ok"
  _count "Upgraded (CVE bypass):" "${_CVE_BYPASSED}" "$_c_ok"
  _count "Skipped:" "${_SKIPPED}" "$_c_dim"
  _count "Warnings:" "${_WARNED}" "$_c_warn"
  _count "Failed:" "${_FAILED}" "$_c_red"
}

# Non-zero exit when an upgrade failed, so topgrade reports the step as failed.
((_FAILED == 0))
