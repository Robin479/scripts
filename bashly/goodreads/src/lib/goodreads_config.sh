# Every config.ini key goodreads reads, for `config list/get/set`. Defaults
# live at each gr::config_get call site; keep in sync.
readonly GR_CONFIG_KEYS=(
  curl_bin
  http_request_interval
  http_challenge_pause
  http_challenge_probe_pct
  http_challenge_max_probes
  fetch_max_consecutive_failures
  book_cache_ttl
)

gr::config_is_known_key() {
  local key="$1" k
  for k in "${GR_CONFIG_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# One-line description for `config list`.
gr::config_describe() {
  case "$1" in
    curl_bin) echo "curl command to run for HTTP requests (see CLAUDE.md's auto-detection cascade for what's used when unset)" ;;
    http_request_interval) echo "minimum time, in seconds, between the starts of any two requests (all goodreads processes), plus up to 50% random extra -- keeps clear of the site's burst detection" ;;
    http_challenge_pause) echo "pause, in seconds, after an incident's first bot challenge -- sits out the site's ~5 min clock-based block" ;;
    http_challenge_probe_pct) echo "each further challenge in an incident (a failed probe) pauses for this % of the time waited in the incident so far" ;;
    http_challenge_max_probes) echo "give up on a request after this many failed probes in one incident" ;;
    fetch_max_consecutive_failures) echo "a 'fetch' run stops after this many failures in a row (0 disables)" ;;
    book_cache_ttl) echo "how long, in seconds, a cached book is considered fresh before 'fetch --all' refetches it" ;;
    *) echo "" ;;
  esac
}

# Default shown by `config list`/`get`.
gr::config_default_display() {
  case "$1" in
    curl_bin) echo "auto-detected -- see CLAUDE.md" ;;
    http_request_interval) echo "$GR_HTTP_REQUEST_INTERVAL_DEFAULT" ;;
    http_challenge_pause) echo "$GR_HTTP_CHALLENGE_PAUSE_DEFAULT" ;;
    http_challenge_probe_pct) echo "$GR_HTTP_CHALLENGE_PROBE_PCT_DEFAULT" ;;
    http_challenge_max_probes) echo "$GR_HTTP_CHALLENGE_MAX_PROBES_DEFAULT" ;;
    fetch_max_consecutive_failures) echo "$GR_FETCH_MAX_CONSECUTIVE_FAILURES_DEFAULT" ;;
    book_cache_ttl) echo "$GR_BOOK_CACHE_TTL_DEFAULT" ;;
    *) echo "" ;;
  esac
}
