# shellcheck shell=bash
# Keep the live ~/.config/mise/mise.lock and its chezmoi source copy in step.
# Both sides change: `mise upgrade` rewrites the live lock, a `git pull` the
# source one. A copy of the lock as of the last sync (the base) tells which
# side moved, so the right one wins without asking, and only a change on
# both sides needs a decision. Sourced by the mise sync hook,
# upgrade-mise-aged.sh and scripts/drift-report.sh; prints nothing itself.

MISE_LOCK_LIVE=${MISE_LOCK_LIVE:-$HOME/.config/mise/mise.lock}
MISE_LOCK_BASE=${MISE_LOCK_BASE:-${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/mise.lock.base}

# This machine's source lock: $MISE_LOCK_SOURCE, else the file the chezmoi
# utils/mise-lock partial names. Prints nothing outside a chezmoi setup or
# when the config pins no tools; the file itself may not exist yet.
mise_lock_source() {
  if [[ -n ${MISE_LOCK_SOURCE:-} ]]; then
    printf '%s\n' "$MISE_LOCK_SOURCE"
    return 0
  fi
  command -v chezmoi >/dev/null 2>&1 || return 0
  local dir name
  dir=$(chezmoi source-path 2>/dev/null) || return 0
  name=$(chezmoi execute-template '{{ includeTemplate "utils/mise-lock" . }}' 2>/dev/null) || return 0
  [[ -z $name ]] || printf '%s/private_dot_config/mise/%s\n' "$dir" "$name"
}

# Prints how the live lock relates to source lock $1:
#   none     no source lock for this machine
#   new      source path known but no file yet (the first machine of a set)
#   missing  no live lock
#   equal    in step
#   source   only the source moved since the last sync (a pull)
#   live     only the live lock moved (an upgrade here)
#   both     both moved, or there is no base to tell
mise_lock_state() {
  local src=${1:-}
  if [[ -z $src ]]; then
    echo none
  elif [[ ! -f $src ]]; then
    echo new
  elif [[ ! -f $MISE_LOCK_LIVE ]]; then
    echo missing
  elif cmp -s "$src" "$MISE_LOCK_LIVE"; then
    echo equal
  elif [[ -f $MISE_LOCK_BASE ]] && cmp -s "$MISE_LOCK_LIVE" "$MISE_LOCK_BASE"; then
    echo source
  elif [[ -f $MISE_LOCK_BASE ]] && cmp -s "$src" "$MISE_LOCK_BASE"; then
    echo live
  else
    echo both
  fi
}

# Record lock $1 as the base of the next comparison.
mise_lock_mark() {
  mkdir -p "${MISE_LOCK_BASE%/*}" && cp "$1" "$MISE_LOCK_BASE"
}

# Source $1 → live, then mark.
mise_lock_pull() {
  mkdir -p "${MISE_LOCK_LIVE%/*}" && cp "$1" "$MISE_LOCK_LIVE" && mise_lock_mark "$1"
}

# Live → source $1, then mark.
mise_lock_push() {
  cp "$MISE_LOCK_LIVE" "$1" && mise_lock_mark "$1"
}
