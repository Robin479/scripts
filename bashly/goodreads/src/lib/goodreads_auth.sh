gr::account_dir() {
  echo "$(gr::data_dir)/accounts/$1"
}

gr::cookie_jar_for() {
  echo "$(gr::account_dir "$1")/cookies.txt"
}

gr::current_account() {
  # Always returns 0 (`if`, not `&&`), so `x="$(gr::current_account)"`
  # survives set -e when there's no current account.
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

# Prints {"id","username","profile_url"} for the session in cookie jar $1
# (from the homepage's profile link); returns 1 if not logged in.
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

# Prints account $1's session state; always returns 0 (safe in $(...)
# under set -e). With --offline, only checks the jar file exists.
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
