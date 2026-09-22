readonly BS_BASE_URL="https://www.beam-shop.de"

bs::data_dir() {
  local dir="${args[--data-path]:-${BEAM_SHOP_DATA:-$HOME/.beam-shop}}"
  mkdir -p "$dir"
  echo "$dir"
}

bs::offline() {
  [[ -n "${args[--offline]:-}" ]]
}

bs::config_file() {
  echo "$(bs::data_dir)/config.ini"
}

# Wrap bashly's own config_get/config_set/etc. to point CONFIG_FILE at our
# resolved data dir first -- see bashly/goodreads' gr::config_get for why
# this is per-call rather than a one-time hook (initialize() runs before
# --data-path is parsed).
bs::config_get() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(bs::config_file)"
  config_get "$@"
}

bs::config_set() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(bs::config_file)"
  config_set "$@"
}

bs::config_del() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(bs::config_file)"
  config_del "$@"
}

bs::config_keys() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(bs::config_file)"
  config_keys "$@"
}

# True when the current command's progress output should be quiet (no
# self-updating status line) -- either --batch was given explicitly, or
# stderr isn't a terminal (a pipe/redirect/log has no "in place" to
# overwrite, and would otherwise fill up with one line per \r). Checks
# stderr, not stdout, because that's where bs::status_line/
# bs::status_line_clear print (see there for why) -- and unlike stdout,
# stderr is never captured by a plain `$(...)`, which several of this
# project's fetch/relink/resize functions are called through to get their
# real return value; status noise on stdout would corrupt that capture
# (confirmed directly: an earlier version leaked raw \r\033[K sequences
# into a captured cover count this way). Must still be called as a plain
# `if`, never via a bare `&&`/command substitution -- `[[ -t 2 ]]` inside
# a `$(...)` would check the *capture pipe*, not the real terminal,
# silently forcing quiet mode on for everyone (same gotcha documented on
# bashly/goodreads' gr::fetch_quiet, there for stdout since none of its
# own status-line callers are captured that way).
bs::fetch_quiet() {
  local batch_flag="$1"
  [[ -n "$batch_flag" ]] && return 0
  [[ -t 2 ]] && return 1
  return 0
}

# Prints $1 as a self-updating status line to stderr -- \r plus
# clear-to-end-of-line so a shorter message never leaves a stray tail of a
# previous, longer one -- never a real newline, so the caller must print
# one of its own, or call bs::status_line_clear, once done overwriting it.
# Does nothing at all if $2 (see bs::fetch_quiet) is non-empty. Always
# stderr, deliberately -- see bs::fetch_quiet's doc comment for why.
bs::status_line() {
  local message="$1" quiet="$2"
  [[ -n "$quiet" ]] && return
  printf '\r\033[K%s' "$message" >&2
}

# Clears whatever's currently on the status line, without printing a
# replacement -- call this right before any persisted line (an outcome,
# an error) that must survive as a normal line rather than get silently
# overwritten by (or garble together with) whatever comes right after it.
# No-op if $1 is non-empty, same as bs::status_line. Always stderr, same
# reasoning.
bs::status_line_clear() {
  local quiet="$1"
  [[ -n "$quiet" ]] || printf '\r\033[K' >&2
}

# Resolves a possibly-relative href (as seen in the shop's own markup,
# e.g. "/serien-abo/...") against BS_BASE_URL. Already-absolute urls are
# returned unchanged.
bs::absolute_url() {
  local url="$1"
  if [[ "$url" == http* ]]; then
    echo "$url"
  else
    echo "${BS_BASE_URL}${url}"
  fi
}
