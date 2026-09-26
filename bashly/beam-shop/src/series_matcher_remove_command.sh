: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"
indexes_raw="${args[--index]:-}"

bs::require_series_file "$series_id" > /dev/null || exit 1

for i in $indexes_raw; do
  if [[ ! "$i" =~ ^[0-9]+$ ]]; then
    echo "error: --index must be a non-negative integer, got: $i" >&2
    exit 1
  fi
done

# highest-to-lowest: removing shifts later indices down by one
# shellcheck disable=SC2207,SC2086 # intentional word-splitting, digits only (validated above)
sorted=($(printf '%s\n' $indexes_raw | sort -rn))

failures=0
for i in "${sorted[@]}"; do
  if bs::remove_series_matcher_at "$series_id" "$i"; then
    echo "$i -> removed"
  else
    failures=$((failures + 1))
  fi
done

echo "Removed $(( ${#sorted[@]} - failures )) of ${#sorted[@]} matcher(s) from series '$series_id'."
[[ "$failures" -eq 0 ]] || exit 1
