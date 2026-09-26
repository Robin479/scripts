: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"
pattern="${args[--pattern]}"
categories_csv="${args[--categories]:-}"

bs::require_series_file "$series_id" > /dev/null || exit 1

if [[ -n "$categories_csv" ]]; then
  IFS=',' read -r -a ids <<< "$categories_csv"
  for id in "${ids[@]}"; do
    if [[ ! -f "$(bs::category_file "$id")" ]]; then
      echo "error: unknown category $id -- run 'categories list' first" >&2
      exit 1
    fi
  done
fi

bs::add_series_matcher "$series_id" "$pattern" "$categories_csv" || exit 1

count="$(jq '(.matchers // []) | length' "$(bs::series_file "$series_id")")"
echo "Matcher added to series '$series_id' at index $((count - 1))."
