: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
key="${args[key]}"
value="${args[value]}"

if ! gr::config_is_known_key "$key"; then
  echo "note: '$key' is not a setting goodreads itself reads -- see 'goodreads config list'" >&2
fi

gr::config_set "$key" "$value"
echo "$key = $value"
