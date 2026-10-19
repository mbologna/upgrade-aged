#!/usr/bin/env bash
# Upgrade mise tools. The age gate itself is mise's own minimum_release_age
# (14d, set in ~/.config/mise/config.toml), which holds back fresh releases on
# every mise install and upgrade, not only this one. This script adds what
# that setting lacks:
#   - a CVE bypass: a tool whose installed version has a known vulnerability
#     (OSV.dev, see lib/osv-check.sh) upgrades now, past the cutoff;
#   - a guard for backends that publish no release dates (vfox:eza, for one),
#     which the cutoff cannot hold back: those are skipped, never upgraded;
#   - syncing the refreshed mise.lock back to the chezmoi source.
# No -e: one failed mise/API call counts as a failure and the run goes on to
# the next tool; pipefail and -u still catch mistakes.
set -uo pipefail

usage() {
  cat <<EOT
Usage: $(basename "$0") [--dry-run] [--help]

Upgrade mise-managed tools to the newest release mise's minimum_release_age
setting allows (14 days in this config).

A tool whose installed version has a known CVE (see OSV_PACKAGES in
lib/osv-check.sh) bypasses the age gate immediately. A tool whose backend
reports no release dates is skipped, because the age gate cannot apply to it.

Options:
  --dry-run    Print what would be upgraded without making any changes.
  --help       Show this help message.

Environment variables:
  MISE_LOCK_AUTOCOMMIT  Auto-commit mise.lock after sync (default: 1)
  MISE_LOCK_AUTOPUSH    Auto-push after auto-commit (default: 0)
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

MISE_LOCK_AUTOCOMMIT=${MISE_LOCK_AUTOCOMMIT:-1}
MISE_LOCK_AUTOPUSH=${MISE_LOCK_AUTOPUSH:-0}

for _cmd in mise jq; do
  command -v "$_cmd" &>/dev/null || {
    _err "$_cmd not found — this script requires mise and jq."
    exit 1
  }
done

CUTOFF=$(mise settings get minimum_release_age 2>/dev/null) || {
  _err "mise minimum_release_age is not set — refusing to upgrade without an age gate"
  exit 1
}

# Summary counters printed at the end of the run.
declare -i _UPGRADED=0 _CVE_BYPASSED=0 _SKIPPED=0 _WARNED=0 _FAILED=0

mise_lock_source_path() {
  local live_lock="$1"
  local lock_src source_dir fallback_src

  lock_src=$(chezmoi source-path "$live_lock" 2>/dev/null || true)
  if [[ -n $lock_src && -f $lock_src ]]; then
    printf '%s\n' "$lock_src"
    return 0
  fi

  source_dir=$(chezmoi source-path 2>/dev/null || true)
  fallback_src="${source_dir}/private_dot_config/mise/private_mise.lock"
  if [[ -n $source_dir && -f $fallback_src ]]; then
    printf '%s\n' "$fallback_src"
    return 0
  fi

  return 1
}

auto_commit_mise_lock() {
  local lock_src="$1"
  local repo_root
  local commit_msg="chore(mise): refresh lockfile"

  repo_root=$(git -C "$(dirname "$lock_src")" rev-parse --show-toplevel 2>/dev/null) || {
    _warn "mise.lock: not in a git repository, skipping auto-commit"
    return
  }

  case "$lock_src" in
  "$repo_root"/*) ;;
  *)
    _warn "mise.lock: source path is outside repository root, skipping auto-commit"
    return
    ;;
  esac

  git -C "$repo_root" add -- "$lock_src" || {
    _err "mise.lock: could not stage file for commit"
    return
  }

  if git -C "$repo_root" diff --cached --quiet -- "$lock_src"; then
    _info "mise.lock: no source changes to commit"
    return
  fi

  # Lockfile refresh is deterministic output; skip hooks to avoid blocking automation.
  if git -C "$repo_root" commit --no-verify -m "$commit_msg" -- "$lock_src" >/dev/null 2>&1; then
    _ok "mise.lock committed to git"
  else
    _err "mise.lock: auto-commit failed"
    return
  fi

  if [[ $MISE_LOCK_AUTOPUSH == "1" ]]; then
    if git -C "$repo_root" push >/dev/null 2>&1; then
      _ok "mise.lock pushed"
    else
      _err "mise.lock: auto-push failed"
    fi
  fi
}

# Runs (or previews, under --dry-run) `mise upgrade <tool>`, passing any extra
# arguments through.
do_upgrade() {
  local tool="$1"
  shift
  if ((DRY_RUN)); then
    _info "[dry-run] would run: mise upgrade $tool $*" "   "
    return 0
  fi
  mise upgrade "$tool" "$@" </dev/null || {
    _err "$tool: upgrade failed"
    ((_FAILED++))
    return 1
  }
}

# Returns 0 if the tool's backend publishes release dates, which is what
# minimum_release_age filters on. Without them mise applies no cutoff at all.
has_release_dates() {
  mise ls-remote "$1" --json 2>/dev/null | jq -e 'any(.[]; .created_at != null)' >/dev/null 2>&1
}

_title "Checking outdated mise tools (age gate: ${CUTOFF}, from mise)"

# Every outdated tool with the cutoff lifted, so the CVE check also sees tools
# whose fix is still younger than the cutoff ...
all_json=$(MISE_MINIMUM_RELEASE_AGE=0s mise outdated --json 2>/dev/null) || {
  _err "mise outdated failed"
  exit 1
}
# ... and the ones mise itself would upgrade now, with the cutoff applied.
eligible_json=$(mise outdated --json 2>/dev/null) || {
  _err "mise outdated failed"
  exit 1
}

if jq -e 'length == 0' <<<"$all_json" >/dev/null; then
  _ok "All mise tools are up to date"
  exit 0
fi

while IFS=$'\t' read -r tool installed latest; do
  [[ -z $latest ]] && continue

  if [[ -n $installed && $installed != "system" ]] && has_vulnerability "$tool" "$installed"; then
    _warn "$tool: CVE in installed v${installed} — bypassing age gate"
    do_upgrade "$tool" --minimum-release-age 0s && ((_CVE_BYPASSED++))
    continue
  fi

  eligible=$(jq -r --arg t "$tool" '.[$t].latest // empty' <<<"$eligible_json")
  if [[ -z $eligible || $eligible == "$installed" ]]; then
    _info "$tool: ${latest} is younger than ${CUTOFF} — held back by mise"
    ((_SKIPPED++))
    continue
  fi

  if ! has_release_dates "$tool"; then
    _warn "$tool: backend publishes no release dates, so the age gate cannot apply — skipping"
    ((_WARNED++))
    continue
  fi

  _ok "$tool: upgrading to ${eligible}"
  do_upgrade "$tool" && ((_UPGRADED++))
done < <(jq -r 'to_entries[] | [.key, (.value.current // ""), (.value.latest // "")] | @tsv' <<<"$all_json")

# Reconcile lock file and prune old versions after any upgrades.
# NOTE: do NOT run `mise install` here — with lockfile=true, that would downgrade
# tools back to whatever the stale lock file says. Instead:
#   1. mise upgrade (above) already wrote the new versions to mise.lock (lockfile=true)
#   2. Sync the updated lock file back to the chezmoi source so the next apply
#      doesn't revert it.
#   3. Prune old cached versions.
TOTAL_UPGRADED=$((_UPGRADED + _CVE_BYPASSED))
if ((TOTAL_UPGRADED > 0)); then
  if ((DRY_RUN)); then
    _title "Reconciling mise environment (${TOTAL_UPGRADED} tool(s) would be upgraded)"
    _info "[dry-run] would sync mise.lock to chezmoi source, auto-commit/push if enabled, and run: mise prune --yes" "   "
  else
    _title "Reconciling mise environment (${TOTAL_UPGRADED} tool(s) upgraded)"

    # Sync updated lock file back to chezmoi source to prevent next apply reverting it.
    MISE_LOCK="${HOME}/.config/mise/mise.lock"
    if [[ -f $MISE_LOCK ]] && command -v chezmoi >/dev/null 2>&1; then
      LOCK_SRC=$(mise_lock_source_path "$MISE_LOCK" 2>/dev/null || true)
      if [[ -n $LOCK_SRC && -f $LOCK_SRC ]]; then
        cp "$MISE_LOCK" "$LOCK_SRC" && _ok "mise.lock synced back to chezmoi source ($LOCK_SRC)"
        if [[ $MISE_LOCK_AUTOCOMMIT == "1" ]] && command -v git >/dev/null 2>&1; then
          auto_commit_mise_lock "$LOCK_SRC"
        fi
      fi
    fi

    if mise prune --yes; then
      _ok "mise prune: old versions removed"
    else
      _err "mise prune failed"
    fi
  fi
fi

_title "Summary"
((DRY_RUN)) && _info "dry-run — no changes were made; counts reflect what would have happened"
# _count label n color: the label default fg; a count above zero in its level
# color, zero plain (a number, not an outcome: doc/color-system.md §4).
_c_red=${_c_ok:+$'\033[31m'} # _c_err gates on stderr; this summary is stdout
_count() {
  local color=$3
  (($2)) || color=''
  printf '%-25s%s%s%s\n' "$1" "$color" "$2" "${color:+$_c_off}"
}
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
