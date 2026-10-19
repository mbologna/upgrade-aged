# shellcheck shell=bash
# Shared output helpers for ~/.local/bin scripts. Source it; do not run it.
# Rendered from .chezmoitemplates/utils/log-sh, like the chezmoi hook helpers.
# --- output helpers (utils/log-sh) ---
# Color only on a terminal and never under NO_COLOR (https://no-color.org):
# piped or logged output stays plain. _err checks stderr, the rest stdout.
# Each line starts with $_log_indent; a second argument overrides it, for
# lines nested under a list. _warn expands backslash escapes (\n).
_c_tty() { [[ -t $1 && -z ${NO_COLOR:-} ]]; }
if _c_tty 1; then
  _c_ok=$'\033[32m' _c_warn=$'\033[33m' _c_dim=$'\033[37m' _c_title=$'\033[1;35m' _c_off=$'\033[0m'
  _c_exec=$'\033[32m'
else
  _c_ok='' _c_warn='' _c_dim='' _c_title='' _c_off='' _c_exec=''
fi
if _c_tty 2; then _c_err=$'\033[31m' _c_err_off=$'\033[0m'; else _c_err='' _c_err_off=''; fi
_log_indent=${_log_indent-}
_ok() { printf '%s%s✓%s %s\n' "${2-$_log_indent}" "$_c_ok" "$_c_off" "$1"; }
_err() { printf '%s%s✗%s %s\n' "${2-$_log_indent}" "$_c_err" "$_c_err_off" "$1" >&2; }
_info() { printf '%s%s→ %s%s\n' "${2-$_log_indent}" "$_c_dim" "$1" "$_c_off"; }
# _hint text [command text command ...]: the arguments alternate prose and
# runnable commands, joined by spaces; each command prints execute.
_hint() {
  local out='' i=0 part
  for part in "$@"; do
    if ((i++ % 2)); then out+=" $_c_exec$part$_c_dim"; else out+=" $part"; fi
  done
  printf '%s%s==>%s%s%s%s\n' "$_log_indent" "$_c_warn" "$_c_off" "$_c_dim" "$out" "$_c_off"
}
_warn() { printf '%s%s⚠%s %b\n' "${2-$_log_indent}" "$_c_warn" "$_c_off" "$1"; }
_skip() { printf '%s%s∅ %s%s\n' "${2-$_log_indent}" "$_c_dim" "$1" "$_c_off"; }
_title() { printf '\n%s▸ %s%s\n' "$_c_title" "$1" "$_c_off"; }

