# shellcheck shell=bash
# Shared output helpers for ~/.local/bin scripts. Source it; do not run it.
# Rendered from .chezmoitemplates/utils/log-sh, like the chezmoi hook helpers.
# --- output helpers (utils/log-sh) ---
# Color only on a terminal and never under NO_COLOR (https://no-color.org):
# piped or logged output stays plain. _err, _warn, _hint and _ask write to
# stderr and check it, so a warning never lands in captured output; the rest
# write to stdout and check it. Each line starts with $_log_indent; a second
# argument overrides it, for lines nested under a list. Text prints as is:
# pass a real newline ($'\n') to break a line.
_c_tty() { [[ -t $1 && -z ${NO_COLOR:-} ]]; }
if _c_tty 1; then
  _c_ok=$'\033[32m' _c_warn=$'\033[33m' _c_dim=$'\033[37m' _c_title=$'\033[1;35m' _c_off=$'\033[0m'
else
  _c_ok='' _c_warn='' _c_dim='' _c_title='' _c_off=''
fi
if _c_tty 2; then
  _c_err=$'\033[31m' _c_err_warn=$'\033[33m' _c_err_dim=$'\033[37m' _c_err_off=$'\033[0m'
  _c_err_exec=$'\033[32m'
else
  _c_err='' _c_err_warn='' _c_err_dim='' _c_err_off='' _c_err_exec=''
fi
_log_indent=${_log_indent-}
_ok() { printf '%s%s✓%s %s\n' "${2-$_log_indent}" "$_c_ok" "$_c_off" "$1"; }
_err() { printf '%s%s✗%s %s\n' "${2-$_log_indent}" "$_c_err" "$_c_err_off" "$1" >&2; }
_info() { printf '%s%s→ %s%s\n' "${2-$_log_indent}" "$_c_dim" "$1" "$_c_off"; }
# _hint text [command text command ...]: the arguments alternate prose and
# runnable commands, joined by spaces; each command prints execute.
_hint() {
  local out='' i=0 part
  for part in "$@"; do
    if ((i++ % 2)); then out+=" $_c_err_exec$part$_c_err_dim"; else out+=" $part"; fi
  done
  printf '%s%s==>%s%s%s%s\n' "$_log_indent" "$_c_err_warn" "$_c_err_off" "$_c_err_dim" "$out" "$_c_err_off" >&2
}
_warn() { printf '%s%s⚠%s %s\n' "${2-$_log_indent}" "$_c_err_warn" "$_c_err_off" "$1" >&2; }
# _ask question [choices]: the prompt before a read, choices subtle
# (default [y/N]); the caller reads the answer.
_ask() { printf '%s? %s %s%s%s ' "$_log_indent" "$1" "$_c_err_dim" "${2-[y/N]}" "$_c_err_off" >&2; }
_skip() { printf '%s%s∅ %s%s\n' "${2-$_log_indent}" "$_c_dim" "$1" "$_c_off"; }
_title() { printf '\n%s▸ %s%s\n' "$_c_title" "$1" "$_c_off"; }

# --- script helpers (not in utils/log-sh: chezmoi hooks embed that, and any
# change there re-runs every run_onchange_ hook) ---
# Red for stdout lists and summaries (deletions, failure counts): _c_err
# follows stderr, so it would stay plain or color the wrong stream.
_c_red=${_c_ok:+$'\033[31m'}
# _count label n color: the label default fg; a count above zero in its level
# color, zero plain (a number, not an outcome: doc/color-system.md §4).
_count() {
  local color=$3
  (($2)) || color=''
  printf '%-25s%s%s%s\n' "$1" "$color" "$2" "${color:+$_c_off}"
}
# _require cmd...: exit 1 naming the first command not on PATH.
_require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      _err "$cmd not found"
      exit 1
    }
  done
}
