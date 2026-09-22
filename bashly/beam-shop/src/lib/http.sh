readonly BS_USER_AGENT='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

# Fallback curl binary when nothing else is configured/found -- see
# bs::init_curl_cmd.
readonly BS_CURL_BIN_DEFAULT="curl"

# curl-impersonate's wrapper script names, checked in this order against
# $PATH -- same cascade/reasoning as bashly/goodreads' own http.sh.
readonly BS_CURL_IMPERSONATE_CANDIDATES=(
  curl_chrome116 curl_chrome110 curl_chrome107 curl_chrome104
  curl_chrome101 curl_chrome100 curl_chrome99 curl_chrome99_android
  curl_edge101 curl_edge99
  curl_ff117 curl_ff109 curl_ff102 curl_ff100 curl_ff98 curl_ff95 curl_ff91esr
  curl_safari15_5 curl_safari15_3
)

readonly BS_CURL_IMPERSONATE_DOCKER_IMAGE="lwthiker/curl-impersonate:0.6.1-chrome"
readonly BS_CURL_IMPERSONATE_DOCKER_WRAPPER="curl_chrome116"

# Default for the http_retry_delays config key (comma-separated seconds).
readonly BS_HTTP_RETRY_DELAYS_DEFAULT="20,100,480"

# Defaults for http_request_delay_min/max (seconds) -- tuned to respect
# www.beam-shop.de's own robots.txt (Crawl-delay: 3).
readonly BS_HTTP_REQUEST_DELAY_MIN_DEFAULT=3
readonly BS_HTTP_REQUEST_DELAY_MAX_DEFAULT=8

# Sleeps if needed so this call returns no sooner than a random point
# between http_request_delay_min/max seconds after its own previous
# return. State lives on disk (each invocation is its own process),
# no locking (single-user CLI). Deliberately silent -- see
# bashly/goodreads' http.sh for why (fires on nearly every request).
bs::throttle() {
  local state_file; state_file="$(bs::data_dir)/.last_request_at"

  local min_delay max_delay
  min_delay="$(bs::config_get http_request_delay_min "$BS_HTTP_REQUEST_DELAY_MIN_DEFAULT")"
  max_delay="$(bs::config_get http_request_delay_max "$BS_HTTP_REQUEST_DELAY_MAX_DEFAULT")"

  if [[ -f "$state_file" ]]; then
    local last; last="$(<"$state_file")"
    local delay=$(( min_delay + RANDOM % (max_delay - min_delay + 1) ))
    local wait=$(( last + delay - $(date +%s) ))
    (( wait > 0 )) && sleep "$wait"
  fi

  date +%s > "$state_file"
}

# Resolves which curl command to run into $BS_CURL_CMD (array) and
# $BS_CURL_UA_OPTS -- same priority cascade and memoization caveats as
# bashly/goodreads' gr::init_curl_cmd (see its own CLAUDE.md for the full
# rationale): curl_bin config key -> curl-impersonate on $PATH -> a
# crafted `docker run` -> plain curl -> hard error. Must be called once by
# each command before any subshell-forking loop (e.g. gr::run_fetch-style
# per-item processing), or the memoization flag never reaches the parent.
bs::init_curl_cmd() {
  if [[ -n "${BS_CURL_CMD_RESOLVED:-}" ]]; then
    return 0
  fi

  local curl_bin
  curl_bin="$(bs::config_get curl_bin "")"

  if [[ -z "$curl_bin" ]]; then
    local candidate
    for candidate in "${BS_CURL_IMPERSONATE_CANDIDATES[@]}"; do
      if command -v "$candidate" > /dev/null 2>&1; then
        curl_bin="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$curl_bin" ]] && command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
    local data_dir
    data_dir="$(bs::data_dir)"
    curl_bin="docker run --rm -u $(id -u):$(id -g) -v ${data_dir}:${data_dir} $BS_CURL_IMPERSONATE_DOCKER_IMAGE $BS_CURL_IMPERSONATE_DOCKER_WRAPPER"
  fi

  if [[ -z "$curl_bin" ]] && command -v "$BS_CURL_BIN_DEFAULT" > /dev/null 2>&1; then
    curl_bin="$BS_CURL_BIN_DEFAULT"
  fi

  if [[ -z "$curl_bin" ]]; then
    echo "error: no usable curl found -- install curl, curl-impersonate, or Docker" >&2
    return 1
  fi

  read -r -a BS_CURL_CMD <<< "$curl_bin"
  BS_CURL_UA_OPTS=()
  [[ "$curl_bin" == "$BS_CURL_BIN_DEFAULT" ]] && BS_CURL_UA_OPTS=(-A "$BS_USER_AGENT")
  BS_CURL_CMD_RESOLVED=1
}

# curl wrapper for a single GET: prints the response body to stdout,
# nothing else. Fails like curl's own --fail. Fails immediately under
# --offline. No cookie jar -- www.beam-shop.de needs no login for anything
# this tool touches.
#
# A 2xx response with an empty body is treated as retryable (same
# WAF/anti-bot signature class bashly/goodreads' gr::http_get already
# handles), retried with backoff from http_retry_delays.
bs::http_get() {
  local url="$1"

  if bs::offline; then
    echo "error: cannot fetch $url -- --offline was given" >&2
    return 1
  fi

  bs::init_curl_cmd || return 1

  local delays_csv
  delays_csv="$(bs::config_get http_retry_delays "$BS_HTTP_RETRY_DELAYS_DEFAULT")"
  local -a delays
  IFS=',' read -r -a delays <<< "$delays_csv"

  local body attempt max_attempts=$((${#delays[@]} + 1))
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    body="$(mktemp)"

    bs::throttle
    if ! "${BS_CURL_CMD[@]}" -sLf "${BS_CURL_UA_OPTS[@]}" "$url" > "$body"; then
      rm -f "$body"
      return 1
    fi

    if [[ -s "$body" ]]; then
      cat "$body"
      rm -f "$body"
      return 0
    fi

    rm -f "$body"
    if (( attempt < max_attempts )); then
      local delay="${delays[$((attempt - 1))]}"
      echo "warning: empty response for $url -- retrying in ${delay}s" >&2
      sleep "$delay"
    fi
  done

  echo "error: $url kept returning an empty response after retries -- likely rate-limited by the site" >&2
  return 1
}

# Downloads $1 (a binary asset, e.g. a cover image) to $2. Same
# offline/throttle/retry-on-empty-body handling as bs::http_get, but
# writes straight to a file instead of stdout (avoids holding image
# bytes in a shell variable/pipe).
bs::http_download() {
  local url="$1" dest="$2"

  if bs::offline; then
    echo "error: cannot fetch $url -- --offline was given" >&2
    return 1
  fi

  bs::init_curl_cmd || return 1

  local delays_csv
  delays_csv="$(bs::config_get http_retry_delays "$BS_HTTP_RETRY_DELAYS_DEFAULT")"
  local -a delays
  IFS=',' read -r -a delays <<< "$delays_csv"

  local attempt max_attempts=$((${#delays[@]} + 1))
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    bs::throttle
    if ! "${BS_CURL_CMD[@]}" -sLf "${BS_CURL_UA_OPTS[@]}" "$url" -o "$dest"; then
      rm -f "$dest"
      return 1
    fi

    if [[ -s "$dest" ]]; then
      return 0
    fi

    if (( attempt < max_attempts )); then
      local delay="${delays[$((attempt - 1))]}"
      echo "warning: empty response for $url -- retrying in ${delay}s" >&2
      sleep "$delay"
    fi
  done

  echo "error: $url kept returning an empty response after retries -- likely rate-limited by the site" >&2
  return 1
}
