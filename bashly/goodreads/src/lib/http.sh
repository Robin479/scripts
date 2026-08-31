readonly GR_USER_AGENT='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

# Default for the http_retry_delays config key (comma-separated seconds) —
# see gr::http_get.
readonly GR_HTTP_RETRY_DELAYS_DEFAULT="20,100,480"

# Defaults for the http_request_delay_min / http_request_delay_max config
# keys (seconds) — see gr::throttle.
readonly GR_HTTP_REQUEST_DELAY_MIN_DEFAULT=3
readonly GR_HTTP_REQUEST_DELAY_MAX_DEFAULT=10

# The one place that establishes COOKIE_JAR's default for account-less
# scraping — sets the real (non-local) global variable to
# gr::generic_cookie_jar unless a caller already set it to something else.
# Called once, globally, from before_hook() (src/before.sh) — see
# gr::http_get below for why the default lives here rather than in it.
gr::init_cookie_jar() {
  : "${COOKIE_JAR:=$(gr::generic_cookie_jar)}"
}

# The cookie jar for account-less requests (public pages — book/shelf/etc.
# scraping that doesn't need a login). Lives at the root of the data
# directory, alongside (not inside) accounts/<id>/. Auto-initialized empty
# on first use, same idea as bashly's own config_load touching CONFIG_FILE
# into existence.
gr::generic_cookie_jar() {
  local jar
  jar="$(gr::data_dir)/cookies.txt"
  [[ -f "$jar" ]] || echo -n > "$jar"
  echo "$jar"
}

# Enforces a minimum spacing between requests: sleeps (if needed) so that
# returning from this call never happens sooner than a random point between
# http_request_delay_min and http_request_delay_max seconds (config keys,
# seconds — see GR_HTTP_REQUEST_DELAY_MIN_DEFAULT/GR_HTTP_REQUEST_DELAY_MAX_DEFAULT
# for the fallbacks) after this same function's own *previous* return. $1 is the
# request URL that's about to be made — kept only for the log message for
# now, a hook for possible future per-host pacing rather than something
# used for that yet.
#
# State (the timestamp of that previous return) lives on disk, not in a
# shell variable: each `goodreads` invocation is its own process, and this
# needs to pace requests across separate invocations, not just within one.
# No locking — this is a single-user CLI tool, concurrent invocations
# racing each other isn't a scenario worth guarding against here. First
# call ever (no state file yet) never waits.
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
    if (( wait > 0 )); then
      echo "throttling request to $url — waiting ${wait}s before continuing" >&2
      sleep "$wait"
    fi
  fi

  date +%s > "$state_file"
}

# shellcheck disable=SC2154 # COOKIE_JAR is meant to be set by the caller, e.g. `COOKIE_JAR=... gr::http_get "$url"`
# curl wrapper for a single GET: prints the response body to stdout and
# nothing else — it's entirely up to the caller how to handle that (redirect
# to a file, capture into a variable, pipe straight into the next command).
# Fails like curl's own --fail: non-2xx responses and transport errors both
# return non-zero with no body on stdout, rather than "successfully"
# printing an error page. Also fails immediately, before touching the
# network at all, if --offline was given — this is the one place that
# enforces it, so every caller gets offline-safety for free rather than
# needing to check gr::offline itself.
#
# Cookie jar is read from the COOKIE_JAR environment variable, not a
# parameter — set it as a one-off prefix on the call, e.g.
# `COOKIE_JAR=path/to/account/cookies.txt gr::http_get "$url"`. This
# function does *not* pick a default when COOKIE_JAR is empty — it just
# makes a cookie-less request in that case. Callers that want the shared
# account-less jar must arrange for COOKIE_JAR to already be set to it
# (gr::init_cookie_jar) before calling in.
#
# A response curl itself considers successful (2xx, so --fail doesn't
# trigger) but with a completely empty body is treated as a *retryable*
# failure, not success — this is AWS WAF's bot-challenge signature on
# goodreads.com (HTTP 202 + empty body + an x-amzn-waf-action: challenge
# header curl's own --fail can't see, since 202 is "success"). Confirmed
# directly, three times: real bulk-fetch batches got exactly this after the
# first 2, then 3, then 3 requests again — a burst allowance then a hard
# block lasting well beyond any reasonable built-in retry window, not a
# fixed request count. Retried here with a backoff read fresh from the
# `http_retry_delays` config key each call (comma-separated seconds, e.g.
# `10,30,90` — see GR_HTTP_RETRY_DELAYS_DEFAULT for the fallback when
# unset) via gr::config_get; still empty after exhausting it means fail
# loudly rather than silently "succeed" with nothing, so callers don't
# cache a challenge page as if it were real content.
gr::http_get() {
  local url="$1"

  if gr::offline; then
    echo "error: cannot fetch $url — --offline was given" >&2
    return 1
  fi

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
    if ! curl -sLf -A "$GR_USER_AGENT" "${cookie_opts[@]}" "$url" > "$body"; then
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
      echo "warning: empty response for $url (looks like a bot challenge) — retrying in ${delay}s" >&2
      sleep "$delay"
    fi
  done

  echo "error: $url kept returning an empty response after retries — likely rate-limited/challenged by the site" >&2
  return 1
}
