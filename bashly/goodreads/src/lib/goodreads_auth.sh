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

# Offline sanity check of cookie file $1 before any request; prints a reason
# and returns 1 if it can't be a usable goodreads.com session.
gr::check_cookie_file() {
  local file="$1"

  if [[ "$(head -c 1 "$file")" == [\[\{] ]]; then
    echo "this is a JSON cookie export, not Netscape cookies.txt format — re-export as cookies.txt (Netscape) instead"
    return 1
  fi

  # Netscape lines: 7 tab-separated fields; "#HttpOnly_" prefixed ones aren't comments.
  local cookie_lines names
  cookie_lines="$(awk -F'\t' '(!/^#/ || /^#HttpOnly_/) && NF >= 7' "$file")"
  if [[ -z "$cookie_lines" ]]; then
    echo "no Netscape-format cookie lines found (7 tab-separated fields) — re-export as cookies.txt (Netscape) format"
    return 1
  fi

  names="$(awk -F'\t' '$1 ~ /(^|[._])goodreads\.com$/ { print $6 }' <<<"$cookie_lines")"
  if [[ -z "$names" ]]; then
    echo "no goodreads.com cookies in this file — export while on www.goodreads.com"
    return 1
  fi
  if ! grep -qx 'at-main' <<<"$names" || ! grep -qx 'session-token' <<<"$names"; then
    echo "goodreads.com cookies found, but no login cookies (at-main, session-token) — export from a browser that's logged in to goodreads.com, with an exporter that includes HttpOnly cookies"
    return 1
  fi
}

# Prints {"id","username","profile_url"} for the session in cookie jar $1
# (from the homepage's profile link). Returns 1 if the homepage couldn't be
# fetched, 2 if it's the logged-out page, 3 if it's neither logged out nor
# has a recognizable profile link (markup change?).
gr::identify_account_from_cookiejar() {
  local cookiejar="$1"
  local home_html
  home_html="$(mktemp)"
  trap 'rm -f "$home_html"; trap - RETURN' RETURN

  COOKIE_JAR="$cookiejar" gr::http_get "https://www.goodreads.com/" > "$home_html" || return 1

  local href
  href="$(xidel -s "$home_html" -e '(//a[contains(@class,"dropdown__trigger--profileMenu")])[1]/@href' 2>/dev/null)" || true

  if [[ ! "$href" =~ /user/show/([0-9]+)-([A-Za-z0-9_-]+) ]]; then
    if grep -q 'href="/user/sign_in"' "$home_html"; then
      return 2
    fi
    return 3
  fi

  jq -n \
    --arg id "${BASH_REMATCH[1]}" \
    --arg username "${BASH_REMATCH[2]}" \
    --arg profile_url "https://www.goodreads.com$href" \
    '{id: $id, username: $username, profile_url: $profile_url}'
}

# Explains a non-zero gr::identify_account_from_cookiejar return code $1.
gr::identify_failure_reason() {
  case "$1" in
    1) echo "couldn't fetch the goodreads.com homepage (network error or bot block — see the error above)" ;;
    2) echo "goodreads.com doesn't accept this session (got the logged-out homepage) — expired, or logged out in the browser since the export?" ;;
    3) echo "the homepage doesn't look logged out, but has no recognizable profile link — goodreads.com markup may have changed (see the account identification notes in CLAUDE.md)" ;;
    *) echo "unknown failure (code $1)" ;;
  esac
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
  # In the data dir, see auth_import_command.sh.
  tmp_cookiejar="$(mktemp -p "$(gr::data_dir)" .cookies.XXXXXX)"
  trap 'rm -f "$tmp_cookiejar"; trap - RETURN' RETURN
  cp "$cookie_jar" "$tmp_cookiejar"

  local live_identity rc=0
  live_identity="$(gr::identify_account_from_cookiejar "$tmp_cookiejar")" || rc=$?
  case "$rc" in
    0) ;;
    2)
      echo "expired or invalid — run 'goodreads auth import' to refresh"
      return
      ;;
    *)
      echo "unknown — $(gr::identify_failure_reason "$rc")"
      return
      ;;
  esac

  local live_id
  live_id="$(jq -r '.id' <<<"$live_identity")"
  if [[ "$live_id" == "$id" ]]; then
    echo "valid"
  else
    echo "present, but resolves to a different account ($live_id) — cookie file may be mismatched"
  fi
}
