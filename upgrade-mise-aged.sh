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

# lib/osv-check.sh declares global associative arrays (declare -gA): bash
# 4.2. macOS's /bin/bash is 3.2; `env bash` finds Homebrew's first.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
  echo "$(basename "$0"): needs bash 4.2 or newer, this is $BASH_VERSION (brew install bash)" >&2
  exit 1
fi

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
  MISE_LOCK_SOURCE      Lock to sync with (default: the chezmoi source's lock
                        for this machine's tool set)
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
# shellcheck disable=SC1091
source "$_lib/mise-lock.sh"

DRY_RUN=0
for _arg in "$@"; do
  case "$_arg" in
  --dry-run) DRY_RUN=1 ;;
  --help | -h) usage ;;
  esac
done

MISE_LOCK_AUTOCOMMIT=${MISE_LOCK_AUTOCOMMIT:-1}
MISE_LOCK_AUTOPUSH=${MISE_LOCK_AUTOPUSH:-0}

_require mise jq

CUTOFF=$(mise settings get minimum_release_age 2>/dev/null) || {
  _err "mise minimum_release_age is not set — refusing to upgrade without an age gate"
  exit 1
}

# Summary counters printed at the end of the run.
declare -i _UPGRADED=0 _CVE_BYPASSED=0 _SKIPPED=0 _WARNED=0 _FAILED=0

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

  # With the repo's hooks: the secret scan and commitlint run on this
  # commit too. A refusal leaves the lock staged for a manual commit.
  if git -C "$repo_root" commit -m "$commit_msg" -- "$lock_src" >/dev/null 2>&1; then
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

# Copies the live lock back to this machine's chezmoi source lock, so the
# next apply doesn't revert it, and commits it. Never when the source also
# moved (LOCK_STATE both): that would undo another machine's upgrade.
sync_lock_back() {
  [[ -n $LOCK_SRC && -f $MISE_LOCK_LIVE && $LOCK_STATE != both ]] || return 0
  if [[ -f $LOCK_SRC ]] && cmp -s "$MISE_LOCK_LIVE" "$LOCK_SRC"; then
    return 0
  fi
  if ((DRY_RUN)); then
    _info "[dry-run] would sync mise.lock to the chezmoi source and auto-commit/push if enabled" "   "
    return 0
  fi
  mise_lock_push "$LOCK_SRC" && _ok "mise.lock synced back to chezmoi source ($LOCK_SRC)"
  if [[ $MISE_LOCK_AUTOCOMMIT == "1" ]] && command -v git >/dev/null 2>&1; then
    auto_commit_mise_lock "$LOCK_SRC"
  fi
}

# Returns 0 if the tool's backend publishes release dates, which is what
# minimum_release_age filters on. Without them mise applies no cutoff at all.
has_release_dates() {
  mise ls-remote "$1" --json 2>/dev/null | jq -e 'any(.[]; .created_at != null)' >/dev/null 2>&1
}

# Start from the newest lock: take the source's when only it moved (another
# machine's upgrade, pulled), so the promotion at the end builds on it.
LOCK_SRC=$(mise_lock_source)
LOCK_STATE=$(mise_lock_state "$LOCK_SRC")
case $LOCK_STATE in
missing | source)
  if ((DRY_RUN)); then
    _info "[dry-run] would update mise.lock from the chezmoi source"
  else
    mise_lock_pull "$LOCK_SRC" && _ok "mise.lock updated from the chezmoi source"
  fi
  ;;
both)
  _warn "mise.lock changed both here and in the chezmoi source: upgrading, but not syncing it back"
  _hint "run" "MISE_LOCK_FORCE_SYNC=1 chezmoi apply" "to take the source's, then re-run"
  ;;
esac

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
  _ok "all mise tools are up to date"
  sync_lock_back
  exit 0
fi

# Fields split on \x1f, not tabs: tab is IFS whitespace, so an empty
# `current` (a tool not installed yet) collapsed and shifted latest into it.
while IFS=$'\x1f' read -r tool installed latest; do
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
done < <(jq -r 'to_entries[] | [.key, (.value.current // ""), (.value.latest // "")] | join("\u001f")' <<<"$all_json")

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
    sync_lock_back
    _info "[dry-run] would run: mise prune --yes" "   "
  else
    _title "Reconciling mise environment (${TOTAL_UPGRADED} tool(s) upgraded)"
    sync_lock_back
    if mise prune --yes; then
      _ok "mise prune: old versions removed"
    else
      _err "mise prune failed"
    fi
  fi
else
  sync_lock_back
fi

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
