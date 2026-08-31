: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[account]}"
account_dir="$(gr::account_dir "$id")"

if [[ ! -d "$account_dir" ]]; then
  echo "error: unknown account: $id (run 'goodreads auth list' to see known accounts)" >&2
  exit 1
fi

gr::set_current "$id"
echo "Current account set to $id."
