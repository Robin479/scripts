: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[account]:-$(gr::current_account)}"

if [[ -z "$id" ]]; then
  echo "No current account. Run 'goodreads auth import <cookie-file>' to start a session, or 'goodreads auth switch <account>' to pick one."
  exit 0
fi

account_dir="$(gr::account_dir "$id")"
profile_file="$account_dir/profile.json"

if [[ ! -f "$profile_file" ]]; then
  echo "error: unknown account: $id (run 'goodreads auth list' to see known accounts)" >&2
  exit 1
fi

username="$(jq -r '.username' "$profile_file")"
profile_url="$(jq -r '.profile_url' "$profile_file")"
identified_at="$(jq -r '.identified_at' "$profile_file")"

current="$(gr::current_account)"
cookies_state="$(gr::cookies_state "$id")"
current_state="no"
[[ "$id" == "$current" ]] && current_state="yes"

echo "account:       $id"
echo "username:      $username"
echo "profile:       $profile_url"
echo "identified at: $identified_at"
echo "cookies:       $cookies_state"
echo "current:       $current_state"
