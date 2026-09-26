: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
product_id="${args[product_id]}"
series_id="${args[--series]}"

bs::require_series_file "$series_id" > /dev/null || exit 1
bs::set_product_override "$product_id" "$series_id" '{"exclude": true}' || exit 1
bs::apply_product_override "$product_id" "$series_id"

echo "$product_id -> excluded from series '$series_id'."
