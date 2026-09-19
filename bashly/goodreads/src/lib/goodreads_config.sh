# Every config.ini key goodreads itself reads -- the registry `config
# list`/`get`/`set` key off. Just the user-facing catalog; the real
# default for each one is still asserted at its own gr::config_get call
# site (http.sh, goodreads_books.sh, ...) -- keep in sync with those.
readonly GR_CONFIG_KEYS=(
  curl_bin
  http_request_delay_min
  http_request_delay_max
  http_retry_delays
  book_cache_ttl
)

gr::config_is_known_key() {
  local key="$1" k
  for k in "${GR_CONFIG_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# One-line description for `config list` -- a case statement, not a
# second array parallel to GR_CONFIG_KEYS, so a key missing from one
# fails loudly (empty default) instead of silently misaligning indices.
gr::config_describe() {
  case "$1" in
    curl_bin) echo "curl command to run for HTTP requests (see CLAUDE.md's auto-detection cascade for what's used when unset)" ;;
    http_request_delay_min) echo "minimum delay, in seconds, enforced between requests" ;;
    http_request_delay_max) echo "maximum delay, in seconds, enforced between requests" ;;
    http_retry_delays) echo "comma-separated retry backoff delays, in seconds, for empty-body WAF-challenge responses" ;;
    book_cache_ttl) echo "how long, in seconds, a cached book is considered fresh before 'fetch --all' refetches it" ;;
    *) echo "" ;;
  esac
}

# What each key falls back to when unset -- shown by `config list`/`get`.
# curl_bin has no single default value (its fallback is the whole
# priority cascade), so it gets a description instead.
gr::config_default_display() {
  case "$1" in
    curl_bin) echo "auto-detected -- see CLAUDE.md" ;;
    http_request_delay_min) echo "$GR_HTTP_REQUEST_DELAY_MIN_DEFAULT" ;;
    http_request_delay_max) echo "$GR_HTTP_REQUEST_DELAY_MAX_DEFAULT" ;;
    http_retry_delays) echo "$GR_HTTP_RETRY_DELAYS_DEFAULT" ;;
    book_cache_ttl) echo "$GR_BOOK_CACHE_TTL_DEFAULT" ;;
    *) echo "" ;;
  esac
}
