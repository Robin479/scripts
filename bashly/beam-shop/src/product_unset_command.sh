: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
product_id="${args[product_id]}"
series_id="${args[--series]}"

bs::require_series_file "$series_id" > /dev/null || exit 1

if bs::unset_product_override "$product_id" "$series_id"; then
  bs::apply_product_override "$product_id" "$series_id"
  echo "$product_id -> override removed for series '$series_id'."
else
  echo "$product_id -> no override was set for series '$series_id'" >&2
  exit 1
fi
