: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
product_id="${args[product_id]}"
series_id="${args[--series]}"
item="${args[--item]}"

if [[ ! "$item" =~ ^[0-9]+$ ]]; then
  echo "error: --item must be a non-negative integer, got: $item" >&2
  exit 1
fi

bs::require_series_file "$series_id" > /dev/null || exit 1
bs::set_product_override "$product_id" "$series_id" "$(jq -n --argjson item "$item" '{item: $item}')" || exit 1
bs::apply_product_override "$product_id" "$series_id"

echo "$product_id -> forced to item $item in series '$series_id'."
