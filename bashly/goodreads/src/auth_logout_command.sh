: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[account]:-$(gr::current_account)}"

if [[ -z "$id" ]]; then
  echo "error: no account given and no current account set" >&2
  exit 1
fi

account_dir="$(gr::account_dir "$id")"

if [[ ! -d "$account_dir" ]]; then
  echo "error: unknown account: $id (run 'goodreads auth list' to see known accounts)" >&2
  exit 1
fi

rm -f "$account_dir/cookies.txt"

current="$(gr::current_account)"
if [[ "$id" == "$current" ]]; then
  rm -f "$(gr::data_dir)/current"
  echo "Logged out of $id and cleared it as the current account."
else
  echo "Logged out of $id."
fi
