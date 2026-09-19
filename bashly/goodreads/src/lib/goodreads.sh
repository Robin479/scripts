gr::data_dir() {
  local dir="${args[--data-path]:-${GOODREADS_DATA:-$HOME/.goodreads}}"
  mkdir -p "$dir"
  echo "$dir"
}

gr::offline() {
  [[ -n "${args[--offline]:-}" ]]
}

gr::config_file() {
  echo "$(gr::data_dir)/config.ini"
}

# Wrap bashly's own config_get/config_set/etc. (from `bashly add config`)
# to point CONFIG_FILE at our resolved data dir first. Per-call, not via a
# hook: initialize() runs before --data-path is parsed.
gr::config_get() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(gr::config_file)"
  config_get "$@"
}

gr::config_set() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(gr::config_file)"
  config_set "$@"
}

gr::config_del() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(gr::config_file)"
  config_del "$@"
}

gr::config_keys() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(gr::config_file)"
  config_keys "$@"
}

# Whether a `fetch` command's live status line should be suppressed: an
# explicit --batch, or stdout not being a terminal (a \r-based live line
# would corrupt a redirected/piped log).
#
# Communicates via exit status, not stdout -- **must** be called as a
# plain statement (`if gr::fetch_quiet "$x"; then quiet=1; fi`), never
# `x="$(gr::fetch_quiet ...)"`. A command substitution's subshell has its
# own stdout redirected to the capture pipe, so `[[ -t 1 ]]` inside would
# check *that pipe*, never the real terminal -- confirmed directly (real
# pty) this used to force quiet mode on unconditionally for everyone,
# undetected because every manual test called this function directly
# rather than through that exact wrapping.
gr::fetch_quiet() {
  local batch_flag="$1"
  [[ -n "$batch_flag" ]] && return 0
  [[ -t 1 ]] && return 1
  return 0
}

# Prints $1 as a self-updating status line -- \r plus clear-to-end-of-line
# so a shorter message never leaves a stray tail of the previous, longer
# one -- never a real newline, so the caller must print one of its own
# (see gr::run_fetch) once done overwriting it. Does nothing at all if $2
# (see gr::fetch_quiet) is non-empty.
gr::status_line() {
  local message="$1" quiet="$2"
  [[ -n "$quiet" ]] && return
  printf '\r\033[K%s' "$message"
}

# Clears whatever's currently on the status line, without printing a
# replacement -- used right before a genuine failure message that must
# survive as a normal, persisted line rather than get silently overwritten
# by (or garble together with) the next status update. No-op if $1 is
# non-empty, same as gr::status_line.
gr::status_line_clear() {
  local quiet="$1"
  [[ -n "$quiet" ]] || printf '\r\033[K'
}

# Like gr::status_line_clear, but for stderr and independent of any
# command's own --batch/quiet state (checks `[[ -t 2 ]]` itself) -- for
# generic code (gr::http_get, gr::refresh_book/gr::refresh_blog) with no
# way to reach a particular `fetch` command's $quiet, whose own
# conclusive failure messages are worth showing even under --batch.
gr::term_clear_line() {
  [[ -t 2 ]] && printf '\r\033[K' >&2
}

# Like gr::status_line but for stderr, independent of --batch/quiet (same
# reasoning as gr::term_clear_line) -- for gr::http_get's own retry
# warning. Falls back to an ordinary persisted line when stderr isn't a
# terminal (no "in place" to overwrite in a log, and a log benefits from
# seeing every retry). Exists because that warning used to always persist,
# which under a sustained bot-challenge block (retrying per attempt *and*
# per affected item) piled up a wall of near-identical lines overwhelming
# the status line it was meant to explain -- this keeps only the latest
# notice visible, in place.
gr::term_status() {
  if [[ -t 2 ]]; then
    printf '\r\033[K%s' "$1" >&2
  else
    printf '%s\n' "$1" >&2
  fi
}

# Runs $2 (a function name) over each remaining positional id, showing
# progress via a self-updating status line -- shared by `books
# fetch`/`blogs fetch`. Calls `fetch_fn <id> <force> <quiet>`, which must:
# on success (0) or skip (2, already cached), print outcome text to
# stdout; on failure, print nothing to stdout, having already printed the
# failure to stderr itself (via gr::status_line_clear first) -- see
# fetch_one in books_fetch_command.sh/blogs_fetch_command.sh. Leaves
# totals in $GR_FETCH_OK/$GR_FETCH_SKIPPED/$GR_FETCH_FAIL for the
# caller's own summary line. **Clears the status line before returning**
# rather than ending it with a newline, so the summary that every call
# site prints right after *replaces* the last status update instead of
# leaving it behind as a stray line.
gr::run_fetch() {
  local quiet="$1" fetch_fn="$2" force="$3"
  shift 3
  GR_FETCH_OK=0
  GR_FETCH_SKIPPED=0
  GR_FETCH_FAIL=0

  local total="$#" processed=0 id status outcome
  for id in "$@"; do
    processed=$((processed + 1))
    gr::status_line "[$processed/$total] $id..." "$quiet"
    # set -e would abort the whole script on $fetch_fn's first non-zero
    # return (2/"skipped" is routine, not a failure) if called bare.
    if outcome="$("$fetch_fn" "$id" "$force" "$quiet")"; then
      status=0
    else
      status=$?
    fi
    [[ -n "$outcome" ]] && gr::status_line "[$processed/$total] $outcome" "$quiet"
    case "$status" in
      0) GR_FETCH_OK=$((GR_FETCH_OK + 1)) ;;
      2) GR_FETCH_SKIPPED=$((GR_FETCH_SKIPPED + 1)) ;;
      *) GR_FETCH_FAIL=$((GR_FETCH_FAIL + 1)) ;;
    esac
  done
  gr::status_line_clear "$quiet"
}
