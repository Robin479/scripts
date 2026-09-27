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

# bashly's config_* with CONFIG_FILE set per call (initialize() runs
# before --data-path is parsed).
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

# Succeeds if the status line should be suppressed (--batch $1 or stdout
# not a terminal). Never call inside $(...): [[ -t 1 ]] would test the pipe.
gr::fetch_quiet() {
  local batch_flag="$1"
  [[ -n "$batch_flag" ]] && return 0
  [[ -t 1 ]] && return 1
  return 0
}

# Overwrites the status line with $1 (no newline); no-op if $2 (quiet) is set.
gr::status_line() {
  local message="$1" quiet="$2"
  [[ -n "$quiet" ]] && return
  printf '\r\033[K%s' "$message"
}

# Clears the status line, e.g. before a persisted error; no-op if $1 (quiet) is set.
gr::status_line_clear() {
  local quiet="$1"
  [[ -n "$quiet" ]] || printf '\r\033[K'
}

# gr::status_line_clear for stderr, if it's a terminal, regardless of --batch.
gr::term_clear_line() {
  [[ -t 2 ]] && printf '\r\033[K' >&2
}

# gr::status_line for stderr regardless of --batch; a plain line if stderr
# isn't a terminal.
gr::term_status() {
  if [[ -t 2 ]]; then
    printf '\r\033[K%s' "$1" >&2
  else
    printf '%s\n' "$1" >&2
  fi
}

readonly GR_FETCH_MAX_CONSECUTIVE_FAILURES_DEFAULT=3

# gr::run_fetch <quiet> <fetch_fn> <force> <id>...: calls
# `fetch_fn <id> <force> <quiet>` per id (0 = ok, 2 = skipped, else failed;
# outcome text on stdout, errors on stderr). Sets GR_FETCH_OK/_SKIPPED/_FAIL
# and GR_FETCH_ABORTED (ids not attempted, empty if none). Stops early on
# gr::blocked_marker_file or fetch_max_consecutive_failures failures in a row.
# Ends with the status line cleared, not newline-terminated.
gr::run_fetch() {
  local quiet="$1" fetch_fn="$2" force="$3"
  shift 3
  GR_FETCH_OK=0
  GR_FETCH_SKIPPED=0
  GR_FETCH_FAIL=0
  GR_FETCH_ABORTED=""

  local max_streak blocked_marker
  max_streak="$(gr::config_get fetch_max_consecutive_failures "$GR_FETCH_MAX_CONSECUTIVE_FAILURES_DEFAULT")"
  blocked_marker="$(gr::blocked_marker_file)"
  # A marker left over from an earlier run says nothing about this one.
  rm -f "$blocked_marker"

  local total="$#" processed=0 streak=0 id status outcome
  for id in "$@"; do
    processed=$((processed + 1))
    gr::status_line "[$processed/$total] $id..." "$quiet"
    # Inside `if` so set -e doesn't abort on a non-zero (e.g. 2 = skipped) return.
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

    [[ "$status" -eq 0 ]] && streak=0
    if [[ "$status" -ne 0 && "$status" -ne 2 ]]; then
      streak=$((streak + 1))
      local reason=""
      if [[ -f "$blocked_marker" ]]; then
        reason="the site is still sending bot challenges after every retry"
      elif (( max_streak > 0 && streak >= max_streak )); then
        reason="$streak failures in a row (fetch_max_consecutive_failures)"
      fi
      if [[ -n "$reason" ]]; then
        GR_FETCH_ABORTED=$((total - processed))
        gr::status_line_clear "$quiet"
        echo "error: stopping early -- $reason; $GR_FETCH_ABORTED item(s) not attempted. Re-run later to resume (cached items are skipped)." >&2
        break
      fi
    fi
  done
  gr::status_line_clear "$quiet"
}
