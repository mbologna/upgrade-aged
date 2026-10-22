#!/usr/bin/env bash
# Upgrade only Homebrew packages whose formula was last updated >= MIN_AGE_DAYS ago.
# No -e: one failed brew/mise/API call counts as a failure and the run
# goes on to the next package; pipefail and -u still catch mistakes.
set -uo pipefail

# Associative arrays and [[ -v array[key] ]] (here and in lib/github-api.sh)
# need bash 4.3. macOS's /bin/bash is 3.2; `env bash` finds Homebrew's first.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "$(basename "$0"): needs bash 4.3 or newer, this is $BASH_VERSION (brew install bash)" >&2
  exit 1
fi

# brew trust and brew.env live under XDG_CONFIG_HOME when it is set and in
# ~/.homebrew otherwise; match the shell's (.zshenv) when run without it.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--help]

Upgrade Homebrew formulae and casks whose latest commit is >= MIN_AGE_DAYS old.
GitHub API calls use the gh CLI login (or GITHUB_TOKEN) for 5000 req/hr, not 60.

A package whose installed version has a known CVE (see OSV_PACKAGES in
lib/osv-check.sh) bypasses the age gate immediately. A package is also held
back if any of its outdated dependencies haven't aged yet, even once its own
version has. Ends with brew autoremove and brew cleanup.

Options:
  --dry-run    Print what would be upgraded without making any changes:
               no brew update, no aged tap, against the formula data on disk.
  --help       Show this help message.

Environment variables:
  MIN_AGE_DAYS       Minimum age in days before upgrading (default: 14)
  MAX_COMMITS_BACK   Number of past commits to search for an aged version (default: 5)
  GITHUB_TOKEN       GitHub token (default: the gh CLI login)
EOF
  exit 0
}

# Shared helpers: output glyphs, GitHub API GET, OSV.dev CVE check and the
# self-updating casks this script upgrades.
_lib="$(dirname "$0")/lib"
# The linter runs without -x, so it cannot follow these (log.sh is also a
# rendered template).
# shellcheck disable=SC1091
source "$_lib/log.sh"
# shellcheck disable=SC1091
source "$_lib/github-api.sh"
# shellcheck disable=SC1091
source "$_lib/osv-check.sh"
# shellcheck disable=SC1091
source "$_lib/brew-updated-casks.sh"

DRY_RUN=0
for _arg in "$@"; do
  case "$_arg" in
  --dry-run) DRY_RUN=1 ;;
  --help | -h) usage ;;
  esac
done

_require brew jq

# Uses GitHub API since modern Homebrew (4.0+) doesn't clone taps locally.
# Authenticated via the gh CLI login (or GITHUB_TOKEN): 5000 req/hr, not 60.
#
# If the latest version hasn't aged yet, the script walks back through the last
# MAX_COMMITS_BACK commits and installs from the most recent aged one (n-1, n-2, …).

MIN_AGE_DAYS=${MIN_AGE_DAYS:-14}
MAX_COMMITS_BACK=${MAX_COMMITS_BACK:-5}
NOW=$(date +%s)

# Since Homebrew 6.0 a plain `brew outdated`/`brew upgrade` also lists an
# auto_updates cask whenever its app bundle is older than the tap. That pulled
# self-updating apps into the age gate, whose fallback then installed an older
# aged version over the newer one the app had installed itself (Signal 8.30.0
# → 8.29.0, which then refused its own database). Turn it off: auto_updates
# casks enter only through BREW_UPDATED_CASKS below. A named
# `brew upgrade --cask` is always greedy, so this does not hold those back.
export HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1

# Local tap used to stage aged formula/cask files for installation.
AGED_TAP_NAME="local/aged"
AGED_TAP_DIR="$(brew --repository)/Library/Taps/local/homebrew-aged"

# Run-scoped state: the current outdated-package and pinned-formula sets
# (refreshed after real changes, not before every check), and summary
# counters printed at the end of the run. GitHub API responses are memoized
# in lib/github-api.sh.
declare -A _OUTDATED=()
declare -A _PINNED=()
declare -A _DRY_UNPINNED=() # formulas unpin_if_aged would unpin, in --dry-run
declare -A _RELINKED=()     # dependents already reinstalled this run, by relink_dependents (dedup)
declare -i _UPGRADED=0 _CVE_BYPASSED=0 _FALLBACK_INSTALLED=0 _UNPINNED=0 _SKIPPED=0 _WARNED=0 _FAILED=0

setup_aged_tap() {
  if [[ ! -d "${AGED_TAP_DIR}/Formula" ]]; then
    mkdir -p "${AGED_TAP_DIR}/Formula" "${AGED_TAP_DIR}/Casks"
    git -C "$AGED_TAP_DIR" init -q
    git -C "$AGED_TAP_DIR" commit --allow-empty -q -m "chore: init aged-tap"
    brew tap "$AGED_TAP_NAME" "$AGED_TAP_DIR" 2>/dev/null || true
  fi
  brew trust "$AGED_TAP_NAME" 2>/dev/null || true
}

tap_to_repo() {
  case "$1" in
  homebrew/core) echo "Homebrew/homebrew-core" ;;
  homebrew/cask) echo "Homebrew/homebrew-cask" ;;
  *) echo "" ;;
  esac
}

# Extracts a formula/cask version from Ruby formula file content (stdin).
# Tries, in order: the top-level `version` field, a version embedded in the
# top-level `url` field, then a `tag:` field. Restricting to the top-level
# `url` (not the whole file) avoids matching unrelated numbers in nested
# patch/resource URLs (e.g. an API path like api.bitbucket.org/2.0/...).
# Prints the version and returns 0, or returns 1 if none was found.
extract_formula_version() {
  python3 -c '
import sys, re
c = sys.stdin.read()
# Top-level version field: exactly 2-space indent (not nested in resource/test blocks).
# Allow commas to match cask version strings like "6.11.0,207".
m = re.search(r"^  version\s+[\"'"'"']([\w.+\-,]+)[\"'"'"']", c, re.MULTILINE)
if m: print(m.group(1)); sys.exit(0)
um = re.search(r"^  url\s+[\"'"'"']([^\"'"'"']+)[\"'"'"']", c, re.MULTILINE)
if um:
    # Trailing suffix handles release-number (imagemagick: 7.1.2-30) and
    # single-letter point-release (tmux/openssl: 3.7c) version schemes.
    m = re.search(r"[-_/]v?([\d]+\.[\d]+(?:\.[\d]+)?(?:-\d+|[a-z])?)", um.group(1))
    if m: print(m.group(1)); sys.exit(0)
m = re.search(r"tag:\s*[\"'"'"']v?([\d]+\.[\d]+(?:\.[\d]+)*)[\"'"'"']", c)
if m: print(m.group(1)); sys.exit(0)
sys.exit(1)
'
}

# Prints the age in days of a commit from a GitHub commits-JSON blob (stdin).
# With no argument, uses the newest commit (data[0]). With a sha, finds that
# specific commit. Returns 1 if the blob is empty or the sha isn't found.
commit_age_days() {
  local date
  date=$(jq -er --arg sha "${1:-}" \
    'first(.[] | select($sha == "" or .sha == $sha) | .commit.committer.date)') || return 1
  iso_age_days "$date"
}

# Prints the shas of commits in a GitHub commits-JSON blob (stdin) that are
# at least MIN_AGE_DAYS old, newest first.
aged_commit_shas() {
  jq -r --argjson now "$NOW" --argjson min "$((MIN_AGE_DAYS * 86400))" \
    '.[] | select($now - (.commit.committer.date | fromdateiso8601) >= $min) | .sha'
}

# Prints tap, ruby_source_path, installed version (casks only; formulae get
# it from installed_formula_version), latest version and the app bundle's own
# version (casks only), separated by \x1f, from brew info JSON on stdin: v1
# (an array) for formulae, v2 for casks. The bundle version is what is really
# on disk: an app that updates itself moves it, while `installed` stays at
# whatever Homebrew last installed.
# \x1f, not a tab: read collapses runs of whitespace separators, which would
# shift the fields after an empty one. Read it with: IFS=$'\x1f' read -r ...
brew_meta() {
  jq -r 'if type == "array" then .[0] | [.tap, .ruby_source_path, "", .versions.stable, ""]
    else .casks[0] | [.tap, .ruby_source_path, (.installed // ""), .version,
      (.bundle_short_version // "")] end
    | map(. // "") | join("\u001f")'
}

# Returns 0 if version $1 is older than version $2. Cask versions such as
# 6.11.0,207 are compared on their first field, which is the one an app
# bundle reports.
version_lt() {
  local a="${1%%,*}" b="${2%%,*}"
  [[ $a != "$b" && $(printf '%s\n' "$a" "$b" | sort -V | head -n1) == "$a" ]]
}

# Runs (or previews, under --dry-run) the upgrade of $pkg, then relinks its
# dependents. On success increments the counter named by $3.
brew_upgrade() {
  local pkg="$1" is_cask="$2"
  local -n counter="$3"
  if ((DRY_RUN)); then
    _info "[dry-run] would run: brew upgrade ${is_cask:+--cask }$pkg" "   "
  elif HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew upgrade ${is_cask:+--cask} "$pkg" </dev/null; then
    refresh_outdated_cache
  else
    _err "$pkg${is_cask:+ (cask)}: upgrade failed"
    ((_FAILED++))
    return 1
  fi
  ((counter++))
  relink_dependents "$pkg" "$is_cask"
}

# Prints the installed version of formula $1 without its _N revision suffix.
installed_formula_version() {
  brew list --versions "$1" 2>/dev/null | awk '{sub(/_[0-9]+$/, "", $2); print $2}'
}

# Refreshes the run-scoped snapshot of outdated packages used by deps_aged().
# Call once at startup and again after any real upgrade/install, not before
# every dependency check — brew outdated is not free to run repeatedly.
refresh_outdated_cache() {
  _OUTDATED=()
  local p
  while IFS= read -r p; do [[ -n $p ]] && _OUTDATED[$p]=1; done < <(brew outdated --quiet 2>/dev/null)
}

# Returns 0 if all outdated transitive dependencies of $pkg have aged enough
# (or carry a CVE in their installed version). Prints an info line for each
# blocking dep and returns 1 if any dep would be pulled in too early.
deps_aged() {
  local pkg="$1" is_cask="${2:-}"
  local dep_list rc=0

  ((${#_OUTDATED[@]})) || return 0

  if [[ -n $is_cask ]]; then
    mapfile -t dep_list < <(brew deps --cask "$pkg" 2>/dev/null)
  else
    mapfile -t dep_list < <(brew deps "$pkg" 2>/dev/null)
  fi
  [[ ${#dep_list[@]} -eq 0 ]] && return 0

  for dep in "${dep_list[@]}"; do
    [[ -v _OUTDATED[$dep] ]] || continue

    local dep_tap dep_ruby_path dep_repo dep_age
    IFS=$'\x1f' read -r dep_tap dep_ruby_path _ _ _ < <(brew info "$dep" --json 2>/dev/null | brew_meta) || continue
    dep_repo=$(tap_to_repo "$dep_tap")
    [[ -z $dep_repo || -z $dep_ruby_path ]] && continue

    fetch_commits "$dep_repo" "$dep_ruby_path" || continue
    dep_age=$(commit_age_days <<<"$GH_BODY") || continue

    if ((dep_age < MIN_AGE_DAYS)); then
      local dep_ver
      dep_ver=$(installed_formula_version "$dep")
      if [[ -n $dep_ver ]] && has_vulnerability "$dep" "$dep_ver"; then
        _warn "dep $dep: CVE in installed v${dep_ver} — allowing dependency upgrade" "   "
        continue
      fi
      _info "dep $dep: only ${dep_age}d old — not aged yet" "   "
      rc=1
    fi
  done

  return $rc
}

# Returns 0 if upgrading $pkg won't strand any installed dependent on a
# now-missing shared library version (e.g. a versioned dylib/SONAME bump).
# Blocks (returns 1, printing an info line per offender) if ANY installed
# dependent is itself outdated — hasn't aged into its own latest yet —
# regardless of whether that dependent could theoretically also upgrade
# right now: we can't generally tell in advance whether a given dependency
# bump will actually change something a dependent links against, so this
# errs conservative. The cost is that a leaf library's own aged upgrade can
# wait a few extra days for its dependents to individually catch up; the
# payoff is that upgrading $pkg here can never leave an already-working,
# already-installed dependent broken (see relink_dependents()'s doc comment
# for how that used to happen with x265 → ffmpeg).
dependents_ready() {
  local pkg="$1" is_cask="${2:-}"
  [[ -n $is_cask ]] && return 0 # nothing installed links against a cask here
  ((${#_OUTDATED[@]})) || return 0

  local dependents rc=0
  mapfile -t dependents < <(brew uses --installed --formula "$pkg" 2>/dev/null)
  for dep in "${dependents[@]}"; do
    [[ -v _OUTDATED[$dep] ]] || continue
    _info "dependent $dep: not aged into its own upgrade yet — holding back $pkg to avoid breaking it" "   "
    rc=1
  done

  return $rc
}

# Fetches the last MAX_COMMITS_BACK commits touching a formula file into
# GH_BODY; returns 1 on API failure (memoized, rate-limit aware). Call it
# directly, not in $(...), or the cache and rate-limit latch are lost.
fetch_commits() {
  github_api_get "https://api.github.com/repos/${1}/commits?path=${2}&per_page=${MAX_COMMITS_BACK}"
}

# Reinstalls installed dependents of $pkg so they relink against the version
# just upgraded/installed. deps_aged() already stops us from upgrading a
# package ahead of its own dependencies; this covers the opposite direction —
# a shared library (e.g. x265) can bump its versioned dylib (SONAME) on
# almost every release, and an already-installed dependent (e.g. ffmpeg) that
# hasn't aged into its own upgrade yet is left pointing at a .dylib file that
# no longer exists until something rebuilds it. De-duped via _RELINKED so a
# shared dependent isn't processed twice in one run and so recursion can't
# loop.
#
# IMPORTANT: a bare `brew reinstall $dep` always installs whatever version is
# currently latest in the tap — homebrew-core formulae aren't multi-version,
# so there is no "reinstall the same older version" operation to ask for.
# For a $dep that hasn't itself aged into its latest version yet, that would
# silently upgrade it past its own age gate — the exact thing this script
# exists to prevent. So: only take the plain-reinstall shortcut when $dep is
# NOT outdated (its installed version already *is* the tap's latest, so
# reinstalling can't change its version — pure relink, no age implications).
# When $dep IS outdated, route it through upgrade_if_aged() instead, the same
# function the main loop would eventually reach it through — it upgrades $dep
# only if $dep's own age/CVE/fallback rules allow it, and already calls
# relink_dependents() itself on success, so transitive propagation happens
# for free. If $dep can't be safely upgraded yet, it's left as-is (possibly
# still broken) rather than bypassing its age gate — it will pick up the fix
# on its own next aged upgrade.
relink_dependents() {
  local pkg="$1" is_cask="${2:-}"
  [[ -n $is_cask ]] && return # casks don't have compiled dependents here

  local dependents
  mapfile -t dependents < <(brew uses --installed --formula "$pkg" 2>/dev/null)
  for dep in "${dependents[@]}"; do
    [[ -v _RELINKED[$dep] ]] && continue
    _RELINKED[$dep]=1

    if [[ -v _OUTDATED[$dep] ]]; then
      _info "$dep: outdated dependent of updated $pkg — routing through age gate instead of a plain reinstall" "   "
      upgrade_if_aged "$dep"
      continue
    fi

    if ((DRY_RUN)); then
      _info "[dry-run] would run: brew reinstall $dep (relink against updated $pkg, same version)" "   "
      continue
    fi

    _info "$dep: relinking against updated $pkg (same version, no age impact)" "   "
    if HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall "$dep" </dev/null; then
      refresh_outdated_cache
      relink_dependents "$dep"
    else
      _err "$dep: relink (reinstall) failed"
      ((_FAILED++))
    fi
  done
}

upgrade_if_aged() {
  local pkg="$1" is_cask="${2:-}"
  local label="$pkg${is_cask:+ (cask)}"

  # Already pinned from a previous run — skip without any API calls.
  # unpin_if_aged() handles unpinning once the latest version has aged.
  [[ -z $is_cask && -v _PINNED[$pkg] ]] && return

  # installed_version is reused for the CVE check and the fallback.
  local json tap ruby_path installed_version latest_version bundle_version
  if [[ -n $is_cask ]]; then
    json=$(brew info --cask "$pkg" --json=v2 2>/dev/null)
  else
    json=$(brew info "$pkg" --json 2>/dev/null)
  fi || {
    _warn "$label: brew info failed, skipping"
    ((_WARNED++))
    return
  }
  IFS=$'\x1f' read -r tap ruby_path installed_version latest_version bundle_version < <(brew_meta <<<"$json")
  [[ -z $is_cask ]] && installed_version=$(installed_formula_version "$pkg")

  local repo
  repo=$(tap_to_repo "$tap")
  if [[ -z $repo || -z $ruby_path ]]; then
    _warn "$label: unknown tap '$tap', skipping"
    ((_WARNED++))
    return
  fi

  local commits_json
  fetch_commits "$repo" "$ruby_path" || {
    if ((GH_RATE_LIMITED)); then
      ((_SKIPPED++))
    else
      _warn "$label: could not fetch commit history, skipping"
      ((_WARNED++))
    fi
    return
  }
  commits_json="$GH_BODY"

  # Age in days of the latest commit.
  local age_days
  age_days=$(commit_age_days <<<"$commits_json") || {
    _warn "$label: could not parse commit date, skipping"
    ((_WARNED++))
    return
  }

  if ((age_days >= MIN_AGE_DAYS)); then
    if ! deps_aged "$pkg" "$is_cask"; then
      _info "$label: ${age_days}d old but has unaged dependencies — skipping"
      ((_SKIPPED++))
      return
    fi
    if ! dependents_ready "$pkg" "$is_cask"; then
      _info "$label: ${age_days}d old but has an unaged installed dependent — skipping"
      ((_SKIPPED++))
      return
    fi
    _ok "$label: ${age_days}d old — upgrading"
    brew_upgrade "$pkg" "$is_cask" _UPGRADED
    return
  fi

  # CVE check: bypass age gate if installed version has known vulnerabilities.
  if [[ -n $installed_version ]] && has_vulnerability "$pkg" "$installed_version"; then
    if ! dependents_ready "$pkg" "$is_cask"; then
      _warn "$label: CVE in installed v${installed_version}, but an installed dependent hasn't aged yet — skipping to avoid breaking it (patch $pkg manually if this is urgent)"
      ((_SKIPPED++))
      return
    fi
    _warn "$label: CVE in installed v${installed_version} — bypassing age gate"
    brew_upgrade "$pkg" "$is_cask" _CVE_BYPASSED
    return
  fi

  # Latest hasn't aged yet — walk back through aged commits looking for a genuinely
  # older version (skip commits that only update bottles/metadata for the same version).
  if [[ -z $latest_version ]]; then
    _warn "$label: could not determine latest version, skipping fallback"
    ((_WARNED++))
    return
  fi

  # Sanity-check: verify the formula file at HEAD actually matches brew's reported version.
  # If it doesn't (e.g. ruby_source_path is stale / points to a legacy cask file),
  # our commit history walk would find wrong versions — skip fallback entirely.
  local head_sha
  head_sha=$(jq -er '.[0].sha' <<<"$commits_json") || {
    _warn "$label: empty commit history, skipping"
    ((_WARNED++))
    return
  }
  local head_content head_ver
  head_content=$(curl -sf --max-time 10 "https://raw.githubusercontent.com/${repo}/${head_sha}/${ruby_path}") || {
    _warn "$label: could not fetch HEAD formula, skipping"
    ((_WARNED++))
    return
  }
  head_ver=$(extract_formula_version <<<"$head_content" 2>/dev/null)
  # Only skip if we successfully extracted a version AND it disagrees with brew info.
  # If extraction failed (empty), treat as inconclusive and proceed.
  if [[ -n $head_ver && $head_ver != "$latest_version" ]]; then
    _info "$label: ruby_source_path version mismatch (got ${head_ver}, expected ${latest_version}) — skipping fallback"
    ((_SKIPPED++))
    return
  fi

  local formula_name
  formula_name=$(basename "$ruby_path" .rb)
  local subdir
  subdir="${is_cask:+Casks}"
  subdir="${subdir:-Formula}"
  local tap_file="${AGED_TAP_DIR}/${subdir}/${formula_name}.rb"

  # For each aged commit, download the formula and check if it carries a different version.
  local aged_sha="" aged_version="" sha
  while IFS= read -r sha; do
    local raw_url="https://raw.githubusercontent.com/${repo}/${sha}/${ruby_path}"
    local formula_content
    formula_content=$(curl -sf --max-time 10 "$raw_url") || continue
    local ver
    ver=$(extract_formula_version <<<"$formula_content" 2>/dev/null) || continue
    if [[ $ver != "$latest_version" ]]; then
      aged_sha="$sha"
      aged_version="$ver"
      ((DRY_RUN)) || printf '%s\n' "$formula_content" >"$tap_file"
      break
    fi
  done < <(aged_commit_shas <<<"$commits_json")

  if [[ -z $aged_sha ]]; then
    _info "$label: only ${age_days}d old — skipping (no older version found in last ${MAX_COMMITS_BACK} commits)"
    ((_SKIPPED++))
    return
  fi

  # If the n-1 version is already installed, just pin it silently (formulas) or skip (casks).
  if [[ $aged_version == "$installed_version" ]]; then
    if [[ -z $is_cask ]]; then
      if ((DRY_RUN)); then
        _info "[dry-run] would run: brew pin $formula_name" "   "
      else
        brew pin "$formula_name" 2>/dev/null
      fi
    fi
    rm -f "$tap_file"
    ((_SKIPPED++))
    return
  fi

  # Never install a fallback older than what is already on disk: a version
  # installed outside this script, or one a cask's app installed by updating
  # itself (only its bundle version shows that), would be downgraded, and
  # apps that migrate their data (Signal's database) then refuse to start.
  local on_disk="$installed_version"
  [[ -n $bundle_version ]] && version_lt "$on_disk" "$bundle_version" && on_disk="$bundle_version"
  if [[ -n $on_disk ]] && ! version_lt "$on_disk" "$aged_version"; then
    _info "$label: aged fallback v${aged_version} is not newer than installed v${on_disk} — skipping (would downgrade)"
    rm -f "$tap_file"
    ((_SKIPPED++))
    return
  fi

  # Compute how old the aged commit is, for messaging.
  local aged_age_days
  aged_age_days=$(commit_age_days "$aged_sha" <<<"$commits_json" 2>/dev/null)

  # This only reports what was *found* — installation can still be blocked
  # below by dependents/pinned-deps checks, so don't say "installing" yet.
  _info "$label: latest v${latest_version} only ${age_days}d old — found aged fallback v${aged_version} (${aged_age_days}d old)"

  # Formulas from homebrew/core conflict with same-named formulas in other taps.
  # Uninstall first; skip if other installed packages depend on this one.
  if [[ -z $is_cask ]]; then
    local dependents
    dependents=$(brew uses --installed "$pkg" 2>/dev/null | paste -sd' ' -)
    if [[ -n $dependents ]]; then
      _info "$label: skipping fallback — required by: ${dependents} (wait for it to age)"
      rm -f "$tap_file"
      ((_SKIPPED++))
      return
    fi
    # If any dependency is currently pinned, brew will refuse to install from a
    # different tap that requires the latest version of that dep.
    local blocked_by
    blocked_by=$(comm -12 \
      <(brew deps "$formula_name" 2>/dev/null | sort) \
      <(brew list --pinned 2>/dev/null | sort) |
      paste -sd' ' -)
    if [[ -n $blocked_by ]]; then
      _info "$label: skipping fallback — pinned dependencies: $blocked_by (wait for them to age)"
      rm -f "$tap_file"
      ((_SKIPPED++))
      return
    fi
    if ((DRY_RUN)); then
      _info "[dry-run] would run: brew uninstall --ignore-dependencies $pkg" "   "
    else
      # Unpin first so pin state doesn't interfere with uninstall.
      brew unpin "$pkg" 2>/dev/null || true
      brew uninstall --ignore-dependencies "$pkg" </dev/null 2>/dev/null || {
        _err "$label: uninstall failed, skipping fallback"
        rm -f "$tap_file"
        ((_FAILED++))
        return
      }
      # Verify brew no longer considers the formula installed (uninstall can exit 0
      # yet leave the keg registered in some edge cases).
      if brew list "$pkg" &>/dev/null; then
        _err "$label: still registered after uninstall, skipping fallback"
        rm -f "$tap_file"
        ((_FAILED++))
        return
      fi
    fi
  fi

  if ((DRY_RUN)); then
    _info "[dry-run] would run: brew install ${is_cask:+--cask --force }${AGED_TAP_NAME}/${formula_name}" "   "
    ((_FALLBACK_INSTALLED++))
    relink_dependents "$pkg" "$is_cask"
    rm -f "$tap_file"
    return
  fi

  _info "$label: installing v${aged_version} (${aged_age_days}d old)"
  # Casks need --force: the same token is already installed (from another
  # tap), and Homebrew otherwise refuses to install over it.
  if brew install ${is_cask:+--cask --force} "${AGED_TAP_NAME}/${formula_name}" </dev/null; then
    if [[ -z $is_cask ]]; then brew pin "$formula_name" 2>/dev/null || true; fi
    ((_FALLBACK_INSTALLED++))
    refresh_outdated_cache
    relink_dependents "$pkg" "$is_cask"
  else
    _err "$label: fallback install failed"
    ((_FAILED++))
    # Restore the latest version so the package isn't left missing/broken.
    if [[ -z $is_cask ]]; then
      brew install "$pkg" </dev/null 2>/dev/null && {
        _ok "$label: restored latest from homebrew/core" "   "
        refresh_outdated_cache
      }
    else
      brew install --cask --force "$pkg" </dev/null 2>/dev/null && {
        _ok "$label: restored latest cask" "   "
        refresh_outdated_cache
      }
    fi
  fi
  rm -f "$tap_file"
}

# Unpin a formula if its latest version has aged past MIN_AGE_DAYS.
# Called before the main upgrade loop so the formula gets picked up by brew outdated.
unpin_if_aged() {
  local pkg="$1"
  local json tap ruby_path repo age_days

  json=$(brew info "$pkg" --json 2>/dev/null) || return
  IFS=$'\x1f' read -r tap ruby_path _ _ _ < <(brew_meta <<<"$json")
  repo=$(tap_to_repo "$tap")
  [[ -z $repo || -z $ruby_path ]] && return

  fetch_commits "$repo" "$ruby_path" || return
  age_days=$(commit_age_days <<<"$GH_BODY") || return

  if ((age_days >= MIN_AGE_DAYS)); then
    if ((DRY_RUN)); then
      _info "$pkg: latest version now ${age_days}d old — [dry-run] would unpin"
      _DRY_UNPINNED[$pkg]=1
      ((_UNPINNED++))
    elif brew unpin "$pkg" 2>/dev/null; then
      _ok "$pkg: latest version now ${age_days}d old — unpinned"
      ((_UNPINNED++))
    fi
  fi
}

# The aged tap is local and has no origin; drop only that complaint. pipefail
# makes a failed update (offline, broken tap) fail the pipeline: warn and go
# on with the formula data already on disk. --dry-run changes nothing, so it
# skips both the update and the tap and reads the data already on disk.
if ((DRY_RUN)); then
  _info "dry-run — skipping brew update and the aged tap; using the formula data on disk"
else
  if ! brew update </dev/null 2>&1 | { grep -Ev "No remote 'origin' in .*/local/homebrew-aged" || true; }; then
    _warn "brew update failed — checking against the existing formula data"
  fi
  setup_aged_tap
fi
refresh_outdated_cache

_title "Unpinning aged formulas"
mapfile -t pinned < <(brew list --pinned 2>/dev/null)
for pkg in "${pinned[@]}"; do
  unpin_if_aged "$pkg"
done

# Snapshot currently-pinned formulas; used by upgrade_if_aged to skip them fast.
# In --dry-run, exclude formulas unpin_if_aged would have unpinned above (it
# didn't unpin for real), so the rest of the preview reflects a real run.
while IFS= read -r _p; do
  [[ -n $_p && ! -v _DRY_UNPINNED[$_p] ]] && _PINNED[$_p]=1
done < <(brew list --pinned 2>/dev/null)

_title "Formulas"
mapfile -t formulas < <(brew outdated --formula --quiet)
for pkg in "${formulas[@]}"; do
  upgrade_if_aged "$pkg"
done

_title "Casks"
# With HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS set (top of this script),
# `brew outdated` skips auto_updates casks, leaving them to their own updater.
# BREW_UPDATED_CASKS (lib/brew-updated-casks.sh) have that updater turned off
# (Sparkle keys in .chezmoidata/macos.toml, `auto-update = off` in the Ghostty
# config) so they update here, age-gated.
# Other auto_updates casks keep self-updating: pulling them in would reinstall
# an aged version over a newer self-installed one.
mapfile -t casks < <(
  {
    brew outdated --cask --quiet
    brew outdated --cask --quiet --greedy-auto-updates |
      grep -Fx -f <(printf '%s\n' "${BREW_UPDATED_CASKS[@]}")
  } | sort -u
)
for cask in "${casks[@]}"; do
  upgrade_if_aged "$cask" cask
done

_title "Cleanup"
# Formulas no longer needed as dependencies, and old versions and downloads.
# Kept here because topgrade's brew cleanup runs only in its own brew steps,
# which this script replaces.
if ((DRY_RUN)); then
  _info "[dry-run] would run: brew autoremove, brew cleanup" "   "
else
  brew autoremove || {
    _warn "brew autoremove failed"
    ((_WARNED++))
  }
  brew cleanup || {
    _warn "brew cleanup failed"
    ((_WARNED++))
  }
fi

_title "Summary"
((DRY_RUN)) && _info "dry-run — no changes were made; counts reflect what would have happened"
# shellcheck disable=SC2154 # _c_* colors come from lib/log.sh
{
  _count "Upgraded (age-gated):" "${_UPGRADED}" "$_c_ok"
  _count "Upgraded (CVE bypass):" "${_CVE_BYPASSED}" "$_c_ok"
  _count "Fallback installs:" "${_FALLBACK_INSTALLED}" "$_c_ok"
  _count "Unpinned (now aged):" "${_UNPINNED}" "$_c_ok"
  _count "Skipped:" "${_SKIPPED}" "$_c_dim"
  _count "Warnings:" "${_WARNED}" "$_c_warn"
  _count "Failed:" "${_FAILED}" "$_c_red"
}

# Non-zero exit when an upgrade failed, so topgrade reports the step as failed.
((_FAILED == 0))
