: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
key="${args[key]}"
value="${args[value]}"

if ! bs::config_is_known_key "$key"; then
  echo "note: '$key' is not a setting beam-shop itself reads -- see 'beam-shop config list'" >&2
fi

bs::config_set "$key" "$value"
echo "$key = $value"
