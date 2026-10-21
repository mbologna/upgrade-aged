# shellcheck shell=bash
# GH_BODY is read by the scripts that source this file.
# shellcheck disable=SC2034
# Shared GitHub REST API GET for the age-gated upgrade scripts. Source it; do
# not run it. Callers may define an integer _WARNED counter.
#
# Usage: github_api_get <url> && use "$GH_BODY"
#
# Sets GH_BODY to the response body and returns 0 on HTTP 200, 1 otherwise.
# Responses (and failures) are memoized by URL for the life of the run. A
# 403/429 rate limit response latches GH_RATE_LIMITED, prints one actionable
# warning, and makes every later call fail fast without another round-trip.
#
# Call it directly, never inside $(...): a command substitution runs in a
# subshell, so the cache, the latch and GH_BODY would be lost on return.
# A token raises the rate limit (60 → 5000 req/hr). $GITHUB_TOKEN wins when set
# (CI); otherwise the first call asks the gh CLI, so the token never has to be
# exported to every process. Without either, requests go out anonymously.

declare -gA _GH_CACHE=()
declare -gi GH_RATE_LIMITED=0
GH_BODY=""
readonly _GH_FAILED="__FETCH_FAILED__"

# Resolved on the first request and kept for the run; empty means anonymous.
_GH_TOKEN=""
declare -gi _GH_TOKEN_RESOLVED=0

# Sets _GH_TOKEN. Call it directly, not in $(...), for the same reason as
# github_api_get.
_github_resolve_token() {
  ((_GH_TOKEN_RESOLVED)) && return 0
  _GH_TOKEN_RESOLVED=1
  _GH_TOKEN=${GITHUB_TOKEN:-}
  if [[ -z $_GH_TOKEN ]] && command -v gh >/dev/null; then
    _GH_TOKEN=$(gh auth token 2>/dev/null) || _GH_TOKEN=""
  fi
}

github_api_get() {
  local url="$1"
  GH_BODY=""

  if [[ -v _GH_CACHE[$url] ]]; then
    [[ ${_GH_CACHE[$url]} == "$_GH_FAILED" ]] && return 1
    GH_BODY="${_GH_CACHE[$url]}"
    return 0
  fi

  _GH_CACHE[$url]="$_GH_FAILED"
  ((GH_RATE_LIMITED)) && return 1

  local curl_args=(-s -w '\n%{http_code}' --max-time 10)
  _github_resolve_token
  # The header goes in on stdin (-H @-), so the token never shows in ps
  local header=""
  if [[ -n $_GH_TOKEN ]]; then
    curl_args+=(-H @-)
    header="Authorization: token ${_GH_TOKEN}"
  fi

  local raw http_code body
  raw=$(curl "${curl_args[@]}" "$url" 2>/dev/null <<<"$header") || return 1
  http_code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"

  if [[ $http_code == "403" || $http_code == "429" ]] && grep -qi "rate limit" <<<"$body"; then
    GH_RATE_LIMITED=1
    _warn "GitHub API rate limit hit — run 'gh auth login' or set GITHUB_TOKEN to raise it (60→5000 req/hr); skipping remaining age checks that need the API"
    [[ -v _WARNED ]] && ((_WARNED++))
    return 1
  fi
  [[ $http_code == "200" ]] || return 1

  _GH_CACHE[$url]="$body"
  GH_BODY="$body"
}

# Prints the whole days between an ISO 8601 UTC timestamp and $NOW (or now).
iso_age_days() {
  jq -nr --arg d "$1" --argjson now "${NOW:-$(date +%s)}" \
    '($d | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t | (($now - $t) / 86400 | floor)'
}
