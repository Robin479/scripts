readonly GR_USER_AGENT='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

# Fallback curl binary when nothing else is configured/found -- see
# gr::init_curl_cmd.
readonly GR_CURL_BIN_DEFAULT="curl"

# curl-impersonate's wrapper script names (see CLAUDE.md), checked in
# this order against $PATH: Chrome/Edge (BoringSSL) before Firefox (NSS)
# before Safari (not a real port, just Chrome + Safari-shaped flags).
readonly GR_CURL_IMPERSONATE_CANDIDATES=(
  curl_chrome116 curl_chrome110 curl_chrome107 curl_chrome104
  curl_chrome101 curl_chrome100 curl_chrome99 curl_chrome99_android
  curl_edge101 curl_edge99
  curl_ff117 curl_ff109 curl_ff102 curl_ff100 curl_ff98 curl_ff95 curl_ff91esr
  curl_safari15_5 curl_safari15_3
)

# The image+wrapper gr::init_curl_cmd's Docker fallback crafts a `docker
# run` around. `:latest` on this image is *Firefox*, not Chrome (confirmed
# directly, see CLAUDE.md) -- hence the explicit version+flavor tag.
readonly GR_CURL_IMPERSONATE_DOCKER_IMAGE="lwthiker/curl-impersonate:0.6.1-chrome"
readonly GR_CURL_IMPERSONATE_DOCKER_WRAPPER="curl_chrome116"

# Default for the http_retry_delays config key (comma-separated seconds) —
# see gr::http_get.
readonly GR_HTTP_RETRY_DELAYS_DEFAULT="20,100,480"

# Defaults for the http_request_delay_min / http_request_delay_max config
# keys (seconds) — see gr::throttle.
readonly GR_HTTP_REQUEST_DELAY_MIN_DEFAULT=3
readonly GR_HTTP_REQUEST_DELAY_MAX_DEFAULT=10

# Sets the global COOKIE_JAR to gr::generic_cookie_jar unless already set.
# Called once from before_hook() (src/before.sh) — see gr::http_get for
# why the default lives here rather than in it.
gr::init_cookie_jar() {
  : "${COOKIE_JAR:=$(gr::generic_cookie_jar)}"
}

# Cookie jar for account-less (login-not-needed) requests — root of the
# data dir, alongside (not inside) accounts/<id>/. Auto-created empty on
# first use, same idea as bashly's own config_load/CONFIG_FILE.
gr::generic_cookie_jar() {
  local jar
  jar="$(gr::data_dir)/cookies.txt"
  [[ -f "$jar" ]] || echo -n > "$jar"
  echo "$jar"
}

# Sleeps if needed so this call returns no sooner than a random point
# between http_request_delay_min/max seconds after its own previous
# return. $1 (URL) unused for now — a hook for possible per-host pacing.
#
# Deliberately silent: unlike gr::http_get's rare WAF-retry warning, this
# fires on nearly every request, and used to print one — during a
# `fetch` command's status line that became a wall of text, one line per
# item, drowning out the display it was meant to replace.
#
# State lives on disk (each invocation is its own process, spans must
# survive across them), no locking (single-user CLI).
gr::throttle() {
  local url="$1"
  local state_file; state_file="$(gr::data_dir)/.last_request_at"

  local min_delay max_delay
  min_delay="$(gr::config_get http_request_delay_min "$GR_HTTP_REQUEST_DELAY_MIN_DEFAULT")"
  max_delay="$(gr::config_get http_request_delay_max "$GR_HTTP_REQUEST_DELAY_MAX_DEFAULT")"

  if [[ -f "$state_file" ]]; then
    local last; last="$(<"$state_file")"
    local delay=$(( min_delay + RANDOM % (max_delay - min_delay + 1) ))
    local wait=$(( last + delay - $(date +%s) ))
    (( wait > 0 )) && sleep "$wait"
  fi

  date +%s > "$state_file"
}

# Resolves which curl command to run into $GR_CURL_CMD (array) and
# $GR_CURL_UA_OPTS -- shared by gr::http_get/gr::http_status. Memoized via
# $GR_CURL_CMD_RESOLVED for the process lifetime: resolved lazily (many
# commands never touch the network) then reused for every later call, so
# a batch fetch doesn't re-probe $PATH/Docker per request.
#
# Priority order, per explicit direction:
#   1. The `curl_bin` config key, if set -- explicit always wins.
#   2. First of GR_CURL_IMPERSONATE_CANDIDATES found on $PATH.
#   3. A `docker run` command built around GR_CURL_IMPERSONATE_DOCKER_IMAGE/
#      _WRAPPER, if `docker info` actually answers (not just the binary
#      existing). Built fresh every process (not a static config string) so
#      its `-u <uid>:<gid>` / `-v <data_dir>:<data_dir>` bind mount are
#      always correct for this run's user/data dir -- getting either wrong
#      silently breaks cookie persistence or leaves root-owned files behind
#      (see CLAUDE.md).
#   4. Plain "curl" (GR_CURL_BIN_DEFAULT), if on $PATH.
#   5. A hard error.
#
# $GR_CURL_UA_OPTS is `-A "$GR_USER_AGENT"` only for the plain-curl case —
# an impersonate target already bakes in its own matching UA/headers, and
# layering a different one on top would create the exact UA/TLS mismatch
# bot detection looks for.
gr::init_curl_cmd() {
  if [[ -n "${GR_CURL_CMD_RESOLVED:-}" ]]; then
    return 0
  fi

  local curl_bin
  curl_bin="$(gr::config_get curl_bin "")"

  if [[ -z "$curl_bin" ]]; then
    local candidate
    for candidate in "${GR_CURL_IMPERSONATE_CANDIDATES[@]}"; do
      if command -v "$candidate" > /dev/null 2>&1; then
        curl_bin="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$curl_bin" ]] && command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
    local data_dir
    data_dir="$(gr::data_dir)"
    curl_bin="docker run --rm -u $(id -u):$(id -g) -v ${data_dir}:${data_dir} $GR_CURL_IMPERSONATE_DOCKER_IMAGE $GR_CURL_IMPERSONATE_DOCKER_WRAPPER"
  fi

  if [[ -z "$curl_bin" ]] && command -v "$GR_CURL_BIN_DEFAULT" > /dev/null 2>&1; then
    curl_bin="$GR_CURL_BIN_DEFAULT"
  fi

  if [[ -z "$curl_bin" ]]; then
    echo "error: no usable curl found -- install curl, curl-impersonate, or Docker" >&2
    return 1
  fi

  read -r -a GR_CURL_CMD <<< "$curl_bin"
  GR_CURL_UA_OPTS=()
  [[ "$curl_bin" == "$GR_CURL_BIN_DEFAULT" ]] && GR_CURL_UA_OPTS=(-A "$GR_USER_AGENT")
  GR_CURL_CMD_RESOLVED=1
}

# shellcheck disable=SC2154 # COOKIE_JAR is meant to be set by the caller, e.g. `COOKIE_JAR=... gr::http_get "$url"`
# curl wrapper for a single GET: prints the response body to stdout,
# nothing else. Fails like curl's own --fail. Fails immediately under
# --offline — enforced here so every caller gets it for free.
#
# Cookie jar comes from the COOKIE_JAR env var, not a parameter (prefix
# form, e.g. `COOKIE_JAR=path gr::http_get "$url"`); empty means no jar.
# Callers wanting the shared account-less jar set it via gr::init_cookie_jar.
#
# A 2xx response with a completely empty body is treated as *retryable*
# failure, not success — AWS WAF's bot-challenge signature on
# goodreads.com (HTTP 202 + empty body, invisible to --fail; confirmed
# directly: bulk fetches hit it after 2-3 requests, a burst allowance
# then a block outlasting any reasonable retry window). Retried with
# backoff from `http_retry_delays` (config key, comma-separated seconds);
# still empty after exhausting it fails loudly rather than caching a
# challenge page as real content.
gr::http_get() {
  local url="$1"

  if gr::offline; then
    echo "error: cannot fetch $url — --offline was given" >&2
    return 1
  fi

  gr::init_curl_cmd || return 1

  local cookie_opts=()
  [[ -n "${COOKIE_JAR:-}" ]] && cookie_opts=(-c "$COOKIE_JAR" -b "$COOKIE_JAR")

  local delays_csv
  delays_csv="$(gr::config_get http_retry_delays "$GR_HTTP_RETRY_DELAYS_DEFAULT")"
  local -a delays
  IFS=',' read -r -a delays <<< "$delays_csv"

  local body attempt max_attempts=$((${#delays[@]} + 1))
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    body="$(mktemp)"

    gr::throttle "$url"
    if ! "${GR_CURL_CMD[@]}" -sLf "${GR_CURL_UA_OPTS[@]}" "${cookie_opts[@]}" "$url" > "$body"; then
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
      gr::term_status "warning: empty response for $url (looks like a bot challenge) — retrying in ${delay}s"
      sleep "$delay"
    fi
  done

  gr::term_clear_line
  echo "error: $url kept returning an empty response after retries — likely rate-limited/challenged by the site" >&2
  return 1
}

# shellcheck disable=SC2154 # COOKIE_JAR is meant to be set by the caller, same convention as gr::http_get
# Prints just the final HTTP status code — e.g. to confirm a 404 is real
# before treating a post as permanently gone (see gr::refresh_blog).
gr::http_status() {
  local url="$1"

  if gr::offline; then
    echo "error: cannot check $url — --offline was given" >&2
    return 1
  fi

  gr::init_curl_cmd || return 1

  local cookie_opts=()
  [[ -n "${COOKIE_JAR:-}" ]] && cookie_opts=(-c "$COOKIE_JAR" -b "$COOKIE_JAR")

  gr::throttle "$url"
  "${GR_CURL_CMD[@]}" -sL -o /dev/null -w '%{http_code}' "${GR_CURL_UA_OPTS[@]}" "${cookie_opts[@]}" "$url"
}
