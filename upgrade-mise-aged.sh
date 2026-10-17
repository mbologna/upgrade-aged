#!/usr/bin/env bash
# Upgrade only mise tools whose latest GitHub release was published >= MIN_AGE_DAYS ago.
# No -e: one failed brew/mise/API call counts as a failure and the run
# goes on to the next package; pipefail and -u still catch mistakes.
set -uo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--help]

Upgrade mise-managed tools whose latest GitHub release is >= MIN_AGE_DAYS old.
Set GITHUB_TOKEN to raise the GitHub API rate limit (60 → 5000 req/hr).

A tool whose installed version has a known CVE (see OSV_PACKAGES in
lib/osv-check.sh) bypasses the age gate immediately.

Options:
  --dry-run    Print what would be upgraded without making any changes.
  --help       Show this help message.

Environment variables:
  MIN_AGE_DAYS   Minimum age in days before upgrading (default: 14)
  GITHUB_TOKEN   GitHub personal access token (optional)
  MISE_LOCK_AUTOCOMMIT  Auto-commit mise.lock after sync (default: 1)
  MISE_LOCK_AUTOPUSH    Auto-push after auto-commit (default: 0)
EOF
  exit 0
}

# Shared helpers: output glyphs, GitHub API GET and OSV.dev CVE check.
_lib="$(dirname "$0")/lib"
# The linter runs without -x, so it cannot follow these (log.sh is also a
# rendered template).
# shellcheck disable=SC1091
source "$_lib/log.sh"
# shellcheck disable=SC1091
source "$_lib/github-api.sh"
# shellcheck disable=SC1091
source "$_lib/osv-check.sh"

DRY_RUN=0
for _arg in "$@"; do
  case "$_arg" in
  --dry-run) DRY_RUN=1 ;;
  --help | -h) usage ;;
  esac
done

# All tools must have a GitHub mapping — unmapped tools are skipped (not silently upgraded).
# Set GITHUB_TOKEN env var to raise API rate limit (60 → 5000 req/hr).

MIN_AGE_DAYS=${MIN_AGE_DAYS:-14}
MISE_LOCK_AUTOCOMMIT=${MISE_LOCK_AUTOCOMMIT:-1}
MISE_LOCK_AUTOPUSH=${MISE_LOCK_AUTOPUSH:-0}
# shellcheck disable=SC2034 # read by iso_age_days in lib/github-api.sh
NOW=$(date +%s)

command -v jq &>/dev/null || {
  _err "jq not found — this script requires jq."
  exit 1
}

# Summary counters printed at the end of the run. GitHub API responses are
# memoized in lib/github-api.sh.
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

# Tool name → GitHub owner/repo mapping.
declare -A GITHUB_REPOS=(
  # Linux CLI tools (mise replaces Homebrew on Linux for these)
  [age]="FiloSottile/age"
  [atuin]="atuinsh/atuin"
  [bat]="sharkdp/bat"
  [btop]="aristocratos/btop"
  [chezmoi]="twpayne/chezmoi"
  [curlie]="rs/curlie"
  [delta]="dandavison/delta"
  [difftastic]="Wilfred/difftastic"
  [doggo]="mr-karan/doggo"
  [dua]="Byron/dua-cli"
  [duf]="muesli/duf"
  [dust]="bootandy/dust"
  [eza]="eza-community/eza"
  [fastfetch]="fastfetch-cli/fastfetch"
  [fd]="sharkdp/fd"
  [fzf]="junegunn/fzf"
  [glow]="charmbracelet/glow"
  [trippy]="fujiapple852/trippy"
  [grex]="pemistahl/grex"
  [hexyl]="sharkdp/hexyl"
  [hyperfine]="sharkdp/hyperfine"
  [just]="casey/just"
  [k9s]="derailed/k9s"
  [kubectl]="kubernetes/kubernetes"
  [ripgrep]="BurntSushi/ripgrep"
  [sd]="chmln/sd"
  [starship]="starship-rs/starship"
  [tlrc]="tldr-pages/tlrc"
  [viddy]="sachaos/viddy"
  [watchexec]="watchexec/watchexec"
  [xh]="ducaale/xh"
  [yazi]="sxyazi/yazi"
  [zoxide]="ajeetdsouza/zoxide"
  # Language runtimes
  [go]="golang/go"
  [maven]="apache/maven"
  [node]="nodejs/node"
  [python]="python/cpython"
  [ruby]="ruby/ruby"
  # Language tools
  [gradle]="gradle/gradle"
  ["pre-commit"]="pre-commit/pre-commit"
  [ruff]="astral-sh/ruff"
  [shellcheck]="koalaman/shellcheck"
  [uv]="astral-sh/uv"
)

# Generate the ordered list of release tag candidates for a given tool+version.
# Eclipse Temurin (java) uses per-major-version repos and non-standard tag format;
# it is handled separately in fetch_java_release_age.
release_tags() {
  local tool="$1" version="$2"
  # Standard formats first (cover most tools)
  echo "v${version}"
  echo "${version}"
  # Tool-specific tag formats
  case "$tool" in
  go) echo "go${version}" ;;            # golang/go: go1.24.3
  ruby) echo "v${version//./_}" ;;      # ruby/ruby: v3_4_3
  maven) echo "maven-${version}" ;;     # apache/maven: maven-3.9.10
  gradle) echo "REL_${version//./_}" ;; # gradle/gradle: REL_9_4_1
  esac
}

# Sets RELEASE_DATE to the release date of the first matching tag candidate. Tries the
# Releases API first (the common case). Some repos (e.g. golang/go) tag
# versions without ever creating a GitHub "Release" object, so this falls
# back to resolving the tag as a plain git ref and using its commit date.
# Returns 1 if nothing matched. Like github_api_get, call it directly, not in
# $(...), so the API cache and rate-limit latch survive.
fetch_release_date() {
  local repo="$1"
  shift
  local tag
  RELEASE_DATE=""
  for tag in "$@"; do
    github_api_get "https://api.github.com/repos/${repo}/releases/tags/${tag}" || continue
    RELEASE_DATE=$(jq -er '.published_at // empty' <<<"$GH_BODY" 2>/dev/null) && return 0
  done
  for tag in "$@"; do
    github_api_get "https://api.github.com/repos/${repo}/commits/${tag}" || continue
    RELEASE_DATE=$(jq -er '.commit.committer.date // empty' <<<"$GH_BODY" 2>/dev/null) && return 0
  done
  return 1
}

# Sets RELEASE_DATE for a tool's release; returns 1 if no tag matched.
fetch_release_age() {
  local repo="$1" tool="$2" version="$3"
  local -a tags
  mapfile -t tags < <(release_tags "$tool" "$version")
  fetch_release_date "$repo" "${tags[@]}"
}

# Eclipse Temurin uses per-major-version repos: adoptium/temurinN-binaries
# Tag format: jdk-21.0.7+6 (strip the mise-added trailing .0.1 patch suffix)
fetch_java_release_age() {
  local version="$1"
  local major="${version%%.*}"
  local repo="adoptium/temurin${major}-binaries"
  # Temurin tag: jdk-21.0.7+6 — mise version may be 21.0.7+6.0.1; strip last segment
  local tag_ver="${version%.*}" # 21.0.7+6.0.1 → 21.0.7+6.0
  tag_ver="${tag_ver%.*}"       # 21.0.7+6.0   → 21.0.7+6
  # Normalise: mise may use + or . as build separator
  tag_ver="${tag_ver//+/.}" # for lookup attempt without +
  fetch_release_date "$repo" "jdk-${version%.*.*}" "jdk-${tag_ver}"
}

# Runs (or previews, under --dry-run) `mise upgrade <tool>`.
do_upgrade() {
  local tool="$1"
  if ((DRY_RUN)); then
    _info "[dry-run] would run: mise upgrade $tool" "   "
    return 0
  fi
  mise upgrade "$tool" </dev/null || {
    _err "$tool: upgrade failed"
    ((_FAILED++))
    return 1
  }
}

# Returns 0 if the tool was (or would be, under --dry-run) upgraded, 1 otherwise.
upgrade_if_aged() {
  local tool="$1" latest="$2"

  # CVE check: bypass age gate if the installed version has known vulnerabilities.
  local installed_ver
  installed_ver=$(mise current "$tool" 2>/dev/null | awk '{print $1}')
  if [[ -n $installed_ver && $installed_ver != "system" ]] && has_vulnerability "$tool" "$installed_ver"; then
    _warn "$tool: CVE in installed v${installed_ver} — bypassing age gate"
    do_upgrade "$tool" || return 1
    ((_CVE_BYPASSED++))
    return 0
  fi

  local age_days
  if [[ $tool == "java" ]]; then
    # Java: special-cased due to Temurin's per-major-version repos and tag format
    fetch_java_release_age "$latest" || {
      if ((GH_RATE_LIMITED)); then
        ((_SKIPPED++))
      else
        _warn "java: could not check Temurin release age for ${latest}, skipping"
        ((_WARNED++))
      fi
      return 1
    }
  else
    local repo="${GITHUB_REPOS[$tool]:-}"
    if [[ -z $repo ]]; then
      _warn "$tool: no GitHub release mapping — skipping (add to GITHUB_REPOS to enable)"
      ((_WARNED++))
      return 1
    fi
    fetch_release_age "$repo" "$tool" "$latest" || {
      if ((GH_RATE_LIMITED)); then
        ((_SKIPPED++))
      else
        _warn "$tool: could not check release age for ${latest}, skipping"
        ((_WARNED++))
      fi
      return 1
    }
  fi
  age_days=$(iso_age_days "$RELEASE_DATE")

  if ((age_days >= MIN_AGE_DAYS)); then
    _ok "$tool: ${latest} is ${age_days}d old — upgrading"
    do_upgrade "$tool" || return 1
    ((_UPGRADED++))
    return 0
  else
    _info "$tool: ${latest} only ${age_days}d old — skipping"
    ((_SKIPPED++))
    return 1
  fi
}

_title "Checking outdated mise tools (age gate: ${MIN_AGE_DAYS}d)"

outdated_json=$(mise outdated --json 2>/dev/null) || {
  _err "mise outdated failed"
  exit 1
}

if jq -e 'length == 0' <<<"$outdated_json" >/dev/null; then
  _ok "All mise tools are up to date"
  exit 0
fi

while IFS=$'\t' read -r tool latest; do
  [[ -z $latest ]] && continue
  upgrade_if_aged "$tool" "$latest"
done < <(jq -r 'to_entries[] | [.key, (.value.latest // "")] | @tsv' <<<"$outdated_json")

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
((DRY_RUN)) && echo "(dry-run — no changes were made; counts reflect what would have happened)"
echo "Upgraded (age-gated):    ${_UPGRADED}"
echo "Upgraded (CVE bypass):   ${_CVE_BYPASSED}"
echo "Skipped:                 ${_SKIPPED}"
echo "Warnings:                ${_WARNED}"
echo "Failed:                  ${_FAILED}"

# Non-zero exit when an upgrade failed, so topgrade reports the step as failed.
((_FAILED == 0))
