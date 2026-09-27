readonly GR_USER_AGENT='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

readonly GR_CURL_BIN_DEFAULT="curl"

# curl-impersonate wrapper names, tried in this order on $PATH.
readonly GR_CURL_IMPERSONATE_CANDIDATES=(
  curl_chrome116 curl_chrome110 curl_chrome107 curl_chrome104
  curl_chrome101 curl_chrome100 curl_chrome99 curl_chrome99_android
  curl_edge101 curl_edge99
  curl_ff117 curl_ff109 curl_ff102 curl_ff100 curl_ff98 curl_ff95 curl_ff91esr
  curl_safari15_5 curl_safari15_3
)

# Docker fallback; `:latest` of this image is Firefox, hence the explicit tag.
readonly GR_CURL_IMPERSONATE_DOCKER_IMAGE="lwthiker/curl-impersonate:0.6.1-chrome"
readonly GR_CURL_IMPERSONATE_DOCKER_WRAPPER="curl_chrome116"

# GR_HTTP_EXPECT for book/blog-post pages, whose parsers start from the canonical link.
# shellcheck disable=SC2034 # used by goodreads_books.sh/goodreads_blogs.sh
readonly GR_HTTP_EXPECT_CANONICAL='<link[^>]*rel=["'"'"']?canonical'

# Defaults COOKIE_JAR to gr::generic_cookie_jar; called from before_hook().
gr::init_cookie_jar() {
  : "${COOKIE_JAR:=$(gr::generic_cookie_jar)}"
}

# Cookie jar for account-less requests; created empty on first use.
gr::generic_cookie_jar() {
  local jar
  jar="$(gr::data_dir)/cookies.txt"
  [[ -f "$jar" ]] || echo -n > "$jar"
  echo "$jar"
}

# Sets GR_CURL_CMD (array) and GR_CURL_UA_OPTS, once per process. Order:
# curl_bin config key, curl-impersonate on $PATH, curl-impersonate via
# Docker (if `docker info` answers), plain curl, else error. Only plain
# curl gets our own -A; impersonate targets bring a matching UA.
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

# Headers (all redirect hops) of the latest gr::http_get attempt. In the
# data dir, not /tmp: the Docker curl only bind-mounts the data dir.
gr::last_response_headers_file() {
  echo "$(gr::data_dir)/.last_response_headers"
}

# Present while the latest gr::http_get gave up on bot challenges; a file,
# not a variable, because gr::run_fetch's fetch_fn runs in a subshell.
gr::blocked_marker_file() {
  echo "$(gr::data_dir)/.last_request_blocked"
}

# Just the final response's header block (after the last "HTTP/" status
# line), CRs stripped -- earlier blocks are redirect hops.
gr::final_response_headers() {
  tr -d '\r' < "$1" | awk '/^HTTP\//{h=""} {h=h $0 "\n"} END{printf "%s", h}'
}

# GET $1, printing only the body; non-2xx, transport error or --offline
# returns 1 with no body. Env (prefix form): COOKIE_JAR (empty = no jar),
# GR_HTTP_EXPECT (ERE a 2xx body must match). A bot challenge (WAF header,
# 202/429/503, empty or unexpected 2xx body) is retried, paced by
# http_pacing.sh, until GR_PACE_GIVE_UP; then sets gr::blocked_marker_file
# and fails. max_attempts is only a safety net.
# shellcheck disable=SC2154 # COOKIE_JAR is set by the caller
gr::http_get() {
  local url="$1"
  local expect="${GR_HTTP_EXPECT:-}"

  if gr::offline; then
    echo "error: cannot fetch $url — --offline was given" >&2
    return 1
  fi

  gr::init_curl_cmd || return 1

  local cookie_opts=()
  [[ -n "${COOKIE_JAR:-}" ]] && cookie_opts=(-c "$COOKIE_JAR" -b "$COOKIE_JAR")

  local max_probes
  max_probes="$(gr::config_get http_challenge_max_probes "$GR_HTTP_CHALLENGE_MAX_PROBES_DEFAULT")"

  local headers_file blocked_marker
  headers_file="$(gr::last_response_headers_file)"
  blocked_marker="$(gr::blocked_marker_file)"

  local body headers status challenge attempt max_attempts=$((2 * (max_probes + 1)))
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    body="$(mktemp)"

    gr::throttle "$url"
    if ! "${GR_CURL_CMD[@]}" -sL -D "$headers_file" "${GR_CURL_UA_OPTS[@]}" "${cookie_opts[@]}" "$url" > "$body"; then
      rm -f "$body"
      return 1
    fi

    headers="$(gr::final_response_headers "$headers_file")"
    status="$(awk 'NR==1{print $2}' <<< "$headers")"

    challenge=""
    if grep -qi '^x-amzn-waf-action:' <<< "$headers"; then
      challenge="HTTP $status, $(grep -i -m1 '^x-amzn-waf-action:' <<< "$headers")"
    elif [[ "$status" == "202" || "$status" == "429" || "$status" == "503" ]]; then
      challenge="HTTP $status"
    elif [[ "$status" == 2* && ! -s "$body" ]]; then
      challenge="HTTP $status, empty body"
    elif [[ "$status" == 2* && -n "$expect" ]] && ! grep -qE -- "$expect" "$body"; then
      challenge="HTTP $status, unexpected page"
    fi

    if [[ -z "$challenge" ]]; then
      rm -f "$blocked_marker"
      gr::pace_report ok
      if [[ "$status" != 2* ]]; then
        rm -f "$body"
        return 1
      fi
      cat "$body"
      rm -f "$body"
      return 0
    fi

    gr::pace_report challenge "$challenge"
    gr::save_bad_response "$body" quiet
    rm -f "$body"
    if (( GR_PACE_GIVE_UP == 1 )); then
      break
    fi
  done

  touch "$blocked_marker"
  gr::term_clear_line
  echo "error: $url kept returning a bot challenge ($challenge) after $attempt attempts ($max_probes failed probes in this incident) — likely rate-limited/challenged by the site; last response saved as $(gr::data_dir)/.last_bad_response.{html,headers}" >&2
  return 1
}

# Copies body $1 plus the last response headers to
# <data_dir>/.last_bad_response.{html,headers}; $2 = "quiet" skips the note.
gr::save_bad_response() {
  local body_file="$1" quiet="${2:-}"
  local base; base="$(gr::data_dir)/.last_bad_response"
  cp "$body_file" "$base.html"
  cp "$(gr::last_response_headers_file)" "$base.headers" 2>/dev/null || true
  [[ -n "$quiet" ]] || echo "note: response saved as $base.{html,headers}" >&2
}

# Prints just the final HTTP status code.
# shellcheck disable=SC2154 # COOKIE_JAR is set by the caller
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
