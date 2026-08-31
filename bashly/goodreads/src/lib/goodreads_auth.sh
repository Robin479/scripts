gr::account_dir() {
  echo "$(gr::data_dir)/accounts/$1"
}

gr::cookie_jar_for() {
  echo "$(gr::account_dir "$1")/cookies.txt"
}

gr::current_account() {
  # NB: always returns 0 (an `if`, unlike `&&`, doesn't propagate a false
  # test's exit status) — bashly runs under `set -e`, so a bare
  # `x="$(gr::current_account)"` at a call site must not fail just because
  # there's no current account yet.
  local current_file
  current_file="$(gr::data_dir)/current"
  if [[ -f "$current_file" ]]; then
    cat "$current_file"
  fi
}

gr::require_current_account() {
  local id
  id="$(gr::current_account)"
  if [[ -z "$id" ]]; then
    echo "No current account selected. Run 'goodreads auth import <cookie-file>' or 'goodreads auth switch <account>'." >&2
    exit 1
  fi
  echo "$id"
}

gr::set_current() {
  echo "$1" > "$(gr::data_dir)/current"
}

# Given a cookie jar, verifies it's an authenticated goodreads.com session by
# fetching the homepage and pulling the personal-nav profile link out of it.
# Prints {"id","username","profile_url"} as JSON on success; returns 1 with
# nothing printed if the session isn't authenticated.
gr::identify_account_from_cookiejar() {
  local cookiejar="$1"
  local home_html
  home_html="$(mktemp)"
  trap 'rm -f "$home_html"' RETURN

  COOKIE_JAR="$cookiejar" gr::http_get "https://www.goodreads.com/" > "$home_html" || return 1

  local href
  href="$(xidel -s "$home_html" -e '(//a[contains(@class,"dropdown__trigger--profileMenu")])[1]/@href' 2>/dev/null)" || true

  if [[ ! "$href" =~ /user/show/([0-9]+)-([A-Za-z0-9_-]+) ]]; then
    return 1
  fi

  jq -n \
    --arg id "${BASH_REMATCH[1]}" \
    --arg username "${BASH_REMATCH[2]}" \
    --arg profile_url "https://www.goodreads.com$href" \
    '{id: $id, username: $username, profile_url: $profile_url}'
}

# Human-readable session state for an account's stored cookie jar. Always
# returns 0 (state is encoded in the printed string, not the exit code) so
# it's safe to call as a bare `x="$(gr::cookies_state ...)"` under set -e.
# Honors the global --offline flag: skips the live network check and just
# reports whether a cookie jar file is present.
gr::cookies_state() {
  local id="$1"
  local cookie_jar
  cookie_jar="$(gr::cookie_jar_for "$id")"

  if [[ ! -f "$cookie_jar" ]]; then
    echo "missing (logged out — run 'goodreads auth import' again)"
    return
  fi

  if gr::offline; then
    echo "present (not checked — offline)"
    return
  fi

  local tmp_cookiejar
  tmp_cookiejar="$(mktemp)"
  trap 'rm -f "$tmp_cookiejar"' RETURN
  cp "$cookie_jar" "$tmp_cookiejar"

  local live_identity
  if ! live_identity="$(gr::identify_account_from_cookiejar "$tmp_cookiejar")"; then
    echo "expired or invalid — run 'goodreads auth import' to refresh"
    return
  fi

  local live_id
  live_id="$(jq -r '.id' <<<"$live_identity")"
  if [[ "$live_id" == "$id" ]]; then
    echo "valid"
  else
    echo "present, but resolves to a different account ($live_id) — cookie file may be mismatched"
  fi
}
