#!/usr/bin/env bash
# Upgrade VS Code extensions to the newest release at least MIN_AGE_DAYS (14)
# days old. VS Code has no release-age setting: extensions.autoUpdate is off
# (settings.jsonc) and topgrade's vscode step is disabled, because both
# install the newest release of every extension the day it ships. This picks,
# per installed extension, the newest Marketplace version that is
#   - a stable release (pre-releases are skipped);
#   - built for this platform, or for every platform;
#   - at least MIN_AGE_DAYS old;
#   - compatible with the installed VS Code (its engine range);
# and installs exactly that version. No downgrades: an extension already
# newer than the window is left alone. No CVE bypass: OSV.dev has no
# ecosystem for VS Code extensions.
# No -e: one failed install counts as a failure and the run goes on to the
# next extension; pipefail and -u still catch mistakes.
set -uo pipefail

# Associative arrays and ${var,,}: bash 4. macOS's /bin/bash is 3.2; `env
# bash` finds Homebrew's first.
if ((BASH_VERSINFO[0] < 4)); then
  echo "$(basename "$0"): needs bash 4 or newer, this is $BASH_VERSION (brew install bash)" >&2
  exit 1
fi

usage() {
  cat <<EOT
Usage: $(basename "$0") [--dry-run] [--help]

Upgrade every VS Code extension to the newest stable Marketplace release at
least MIN_AGE_DAYS days old that the installed VS Code supports. An
extension already newer than the window is left as it is.

Options:
  --dry-run    Print what would be upgraded without making any changes.
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

# Machines without VS Code (servers, the minimal profile) have nothing to do
if ! command -v code >/dev/null 2>&1; then
  _skip "code not found — no VS Code extensions to upgrade"
  exit 0
fi
_require curl jq

MARKETPLACE=https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery

# Summary counters printed at the end of the run.
declare -i _UPGRADED=0 _SKIPPED=0 _WARNED=0 _FAILED=0

# The Marketplace's name for this machine's builds (targetPlatform)
platform() {
  local os arch
  case "$(uname -s)" in
  Darwin) os=darwin ;;
  *) os=linux ;;
  esac
  case "$(uname -m)" in
  arm64 | aarch64) arch=arm64 ;;
  *) arch=x64 ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}

# True when version $1 sorts after $2.
newer_than() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

# Reads the Marketplace answer on stdin; prints "id<TAB>version" per
# extension, the version empty when none qualifies. flags 17 =
# IncludeVersions (1) + IncludeVersionProperties (16).
# shellcheck disable=SC2016 # $vars are jq's
ELIGIBLE='
def ver: sub("^[^0-9]*"; "") | split("-")[0] | split(".") | map(tonumber? // 0);
def props: reduce (.properties // [])[] as $p ({}; .[$p.key] = $p.value);
.results[0].extensions[]
| (.publisher.publisherName + "." + .extensionName | ascii_downcase) as $id
| [ .versions[]
    | props as $p
    | select($p["Microsoft.VisualStudio.Code.PreRelease"] != "true")
    | select((.targetPlatform // "universal") as $t
        | $t == "universal" or $t == $platform)
    | select((.lastUpdated | sub("\\.[0-9]+"; "") | fromdate) <= $cutoff)
    | select(($p["Microsoft.VisualStudio.Code.Engine"] // "*") as $e
        | $e == "*" or ($e | ver) <= ($code | ver))
    | .version ]
| (sort_by(ver) | last) as $v
| "\($id)\t\($v // "")"'

do_upgrade() {
  local id="$1" version="$2"
  if ((DRY_RUN)); then
    _info "[dry-run] would run: code --install-extension $id@$version --force" "   "
    return 0
  fi
  code --install-extension "$id@$version" --force </dev/null >/dev/null 2>&1 || {
    _err "$id: install of v${version} failed"
    ((_FAILED++))
    return 1
  }
}

_title "Checking VS Code extensions (age gate: ${MIN_AGE_DAYS} days)"

code_version=$(code --version 2>/dev/null | head -n 1)
if ! [[ $code_version =~ ^[0-9]+\.[0-9]+ ]]; then
  _err "could not read the VS Code version from 'code --version'"
  exit 1
fi
installed=$(code --list-extensions --show-versions 2>/dev/null) || {
  _err "code --list-extensions failed"
  exit 1
}
if [[ -z $installed ]]; then
  _ok "no VS Code extensions installed"
  exit 0
fi

query=$(jq -Rn '[inputs | select(length > 0) | split("@")[0]]
  | {filters: [{criteria: map({filterType: 7, value: .}), pageSize: length}], flags: 17}' \
  <<<"$installed")
answer=$(curl -fsS --max-time 60 -X POST "$MARKETPLACE" \
  -H 'Accept: application/json;api-version=7.2-preview.1' \
  -H 'Content-Type: application/json' --data "$query") || {
  _err "the Marketplace query failed"
  exit 1
}
cutoff=$(($(date +%s) - MIN_AGE_DAYS * 86400))
declare -A eligible=()
while IFS=$'\t' read -r id version; do
  eligible[$id]=$version
done < <(jq -r --argjson cutoff "$cutoff" --arg code "$code_version" \
  --arg platform "$(platform)" "$ELIGIBLE" <<<"$answer")

while IFS=@ read -r id current; do
  [[ -z $id ]] && continue
  key=${id,,}
  if [[ -z ${eligible[$key]+set} ]]; then
    _warn "$id: not on the Marketplace (a VSIX or a delisted extension) — skipping"
    ((_WARNED++))
    continue
  fi
  target=${eligible[$key]}
  if [[ -z $target ]]; then
    _info "$id: no stable release at least ${MIN_AGE_DAYS} days old fits VS Code ${code_version}"
    ((_SKIPPED++))
  elif [[ $target == "$current" ]]; then
    _info "$id: v${current} is the newest release at least ${MIN_AGE_DAYS} days old"
    ((_SKIPPED++))
  elif newer_than "$current" "$target"; then
    _info "$id: installed v${current} is newer than the window allows (v${target}) — leaving it"
    ((_SKIPPED++))
  else
    _ok "$id: upgrading v${current} → v${target}"
    do_upgrade "$id" "$target" && ((_UPGRADED++))
  fi
done <<<"$installed"

_title "Summary"
((DRY_RUN)) && _info "dry-run — no changes were made; counts reflect what would have happened"
# shellcheck disable=SC2154 # _c_* colors come from lib/log.sh
{
  _count "Upgraded (age-gated):" "${_UPGRADED}" "$_c_ok"
  _count "Skipped:" "${_SKIPPED}" "$_c_dim"
  _count "Warnings:" "${_WARNED}" "$_c_warn"
  _count "Failed:" "${_FAILED}" "$_c_red"
}

# Non-zero exit when an upgrade failed, so topgrade reports the step as failed.
((_FAILED == 0))
