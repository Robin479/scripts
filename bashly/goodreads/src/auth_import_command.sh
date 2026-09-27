: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
cookie_file="${args[cookie_file]}"

if [[ ! -f "$cookie_file" ]]; then
  echo "error: cookie file not found: $cookie_file" >&2
  exit 1
fi
if [[ ! -s "$cookie_file" ]]; then
  echo "error: cookie file is empty: $cookie_file" >&2
  exit 1
fi
if ! reason="$(gr::check_cookie_file "$cookie_file")"; then
  echo "error: $cookie_file: $reason" >&2
  exit 1
fi

# Inside the data dir: the Docker curl fallback only mounts that, a /tmp jar
# would silently be invisible to it (cookie-less request).
tmp_cookiejar="$(mktemp -p "$(gr::data_dir)" .cookies.XXXXXX)"
trap 'rm -f "$tmp_cookiejar"' EXIT
cp "$cookie_file" "$tmp_cookiejar"

rc=0
identity="$(gr::identify_account_from_cookiejar "$tmp_cookiejar")" || rc=$?
if ((rc != 0)); then
  echo "error: could not identify an account from $cookie_file: $(gr::identify_failure_reason "$rc")" >&2
  exit 1
fi

id="$(jq -r '.id' <<<"$identity")"
username="$(jq -r '.username' <<<"$identity")"
profile_url="$(jq -r '.profile_url' <<<"$identity")"

account_dir="$(gr::account_dir "$id")"
mkdir -p "$account_dir"
mv "$tmp_cookiejar" "$account_dir/cookies.txt"

jq -n \
  --arg id "$id" \
  --arg username "$username" \
  --arg profile_url "$profile_url" \
  --arg identified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{id: $id, username: $username, profile_url: $profile_url, identified_at: $identified_at}' \
  > "$account_dir/profile.json"

gr::set_current "$id"

echo "Logged in as $username (id $id) — set as current account."
