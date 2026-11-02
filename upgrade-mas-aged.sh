#!/usr/bin/env bash
# Upgrade Mac App Store apps whose current release is at least MIN_AGE_DAYS
# (14) days old. App Store automatic updates are off (the macOS hook) and
# topgrade's mas step is disabled, because both install every update the day
# it ships. For each app `mas outdated` lists, the iTunes Lookup API gives
# the release date of the version the App Store serves
# (currentVersionReleaseDate); the app upgrades only once that is old enough.
# The App Store serves only its newest version, so there is no older aged
# version to fall back to: a young release waits. No CVE bypass: OSV.dev has
# no ecosystem for App Store apps.
# No -e: one failed lookup or update counts and the run goes on to the next
# app; pipefail and -u still catch mistakes.
set -uo pipefail

usage() {
  cat <<EOT
Usage: $(basename "$0") [--dry-run] [--days N] [--help]

Upgrade every outdated Mac App Store app whose current release is at least
MIN_AGE_DAYS days old, by its App Store release date. A younger release is
held back until it ages.

Options:
  --dry-run    Print what would be upgraded without making any changes.
  --days N     Minimum release age in days (overrides MIN_AGE_DAYS).
  --help       Show this help message.

Environment variables:
  MIN_AGE_DAYS  Minimum release age in days (default: 14)
EOT
  exit 0
}

_lib="$(dirname "$0")/lib"
# The linter runs without -x, so it cannot follow this (log.sh is also a
# rendered template).
# shellcheck disable=SC1091
source "$_lib/log.sh"

DRY_RUN=0
while (($#)); do
  case "$1" in
  --dry-run) DRY_RUN=1 ;;
  --days)
    if (($# < 2)); then
      _err "--days needs a number of days"
      exit 1
    fi
    MIN_AGE_DAYS=$2
    shift
    ;;
  --days=*) MIN_AGE_DAYS=${1#--days=} ;;
  --help | -h) usage ;;
  *)
    _err "unknown option: $1"
    exit 1
    ;;
  esac
  shift
done

MIN_AGE_DAYS=${MIN_AGE_DAYS:-14}
if ! [[ $MIN_AGE_DAYS =~ ^[0-9]+$ ]]; then
  _err "MIN_AGE_DAYS must be a whole number of days, not '$MIN_AGE_DAYS'"
  exit 1
fi

_require mas jq curl

# Summary counters printed at the end of the run.
declare -i _UPGRADED=0 _SKIPPED=0 _WARNED=0 _FAILED=0

# Prints "version<TAB>age in days" of the release the App Store serves for
# app id $1, from the iTunes Lookup API; returns 1 when the lookup fails or
# does not know the app.
store_release() {
  local body
  body=$(curl -sf --max-time 10 "https://itunes.apple.com/lookup?id=$1") || return 1
  jq -er --argjson now "$(date +%s)" '
    .results[0] // empty
    | select(.version and .currentVersionReleaseDate)
    | [.version,
       ((($now - (.currentVersionReleaseDate | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 86400) | floor)]
    | @tsv' <<<"$body"
}

# Runs (or previews, under --dry-run) the update of app id $1 ($2 its name).
# mas asks for the password it needs itself, as for topgrade's mas step.
do_update() {
  if ((DRY_RUN)); then
    _info "[dry-run] would run: mas update $1" "   "
    return 0
  fi
  mas update "$1" </dev/null || {
    _err "$2: update failed"
    ((_FAILED++))
    return 1
  }
}

_title "Checking outdated apps (age gate: ${MIN_AGE_DAYS} days)"

# One JSON object per outdated app: adamID, name, version (installed) and
# newVersion.
if ! outdated=$(mas outdated --json 2>/dev/null); then
  _err "mas outdated failed (signed in to the App Store?)"
  exit 1
fi
apps=$(jq -r '[.adamID, .name, .version, .newVersion] | @tsv' <<<"$outdated") || {
  _err "could not parse mas outdated --json"
  exit 1
}
if [[ -z $apps ]]; then
  _ok "all App Store apps are up to date"
  exit 0
fi

while IFS=$'\t' read -r id name installed latest; do
  [[ -z $id ]] && continue

  if ! release=$(store_release "$id"); then
    _warn "$name: App Store lookup failed — skipping"
    ((_WARNED++))
    continue
  fi
  IFS=$'\t' read -r store_version age_days <<<"$release"

  # The date belongs to the version the lookup returns: if that is not the
  # version mas would install, it says nothing about it.
  if [[ $store_version != "$latest" ]]; then
    _warn "$name: App Store lookup reports v${store_version}, mas offers v${latest} — skipping"
    ((_WARNED++))
    continue
  fi

  if ((age_days < MIN_AGE_DAYS)); then
    _info "$name: v${latest} only ${age_days}d old — skipping"
    ((_SKIPPED++))
    continue
  fi

  _ok "$name: v${latest} ${age_days}d old — upgrading from v${installed}"
  do_update "$id" "$name" && ((_UPGRADED++))
done <<<"$apps"

_title "Summary"
((DRY_RUN)) && _info "dry-run — no changes were made; counts reflect what would have happened"
# shellcheck disable=SC2154 # _c_* colors come from lib/log.sh
{
  _count "Upgraded (age-gated):" "${_UPGRADED}" "$_c_ok"
  _count "Skipped:" "${_SKIPPED}" "$_c_dim"
  _count "Warnings:" "${_WARNED}" "$_c_warn"
  _count "Failed:" "${_FAILED}" "$_c_red"
}

# Non-zero exit when an update failed, so topgrade reports the step as failed.
((_FAILED == 0))
