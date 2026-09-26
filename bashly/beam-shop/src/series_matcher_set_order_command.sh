: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"
indexes_raw="${args[--index]:-}"

bs::require_series_file "$series_id" > /dev/null || exit 1

if [[ -z "$indexes_raw" ]]; then
  echo "error: give at least one --index" >&2
  exit 1
fi

for i in $indexes_raw; do
  if [[ ! "$i" =~ ^[0-9]+$ ]]; then
    echo "error: --index must be a non-negative integer, got: $i" >&2
    exit 1
  fi
done

# shellcheck disable=SC2206 # intentional word-splitting, order preserved
front=($indexes_raw)

bs::reorder_series_matchers "$series_id" "${front[@]}" || exit 1

echo "Matchers of series '$series_id' reordered."
bs::print_series_matchers_table "$series_id"
