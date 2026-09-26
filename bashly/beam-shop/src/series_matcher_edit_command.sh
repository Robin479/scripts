: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"
index="${args[--index]}"
pattern="${args[--pattern]:-}"
categories_csv="${args[--categories]:-}"
add_categories_csv="${args[--add-categories]:-}"
remove_categories_csv="${args[--remove-categories]:-}"

bs::require_series_file "$series_id" > /dev/null || exit 1

if [[ ! "$index" =~ ^[0-9]+$ ]]; then
  echo "error: --index must be a non-negative integer, got: $index" >&2
  exit 1
fi

if [[ -z "$pattern" && -z "$categories_csv" && -z "$add_categories_csv" && -z "$remove_categories_csv" ]]; then
  echo "error: give at least one of --pattern, --categories, --add-categories, --remove-categories" >&2
  exit 1
fi

if [[ -n "$categories_csv" && ( -n "$add_categories_csv" || -n "$remove_categories_csv" ) ]]; then
  echo "error: --categories is a full replacement, mutually exclusive with --add-categories/--remove-categories" >&2
  exit 1
fi

for id_list in "$categories_csv" "$add_categories_csv"; do
  [[ -n "$id_list" ]] || continue
  IFS=',' read -r -a ids <<< "$id_list"
  for id in "${ids[@]}"; do
    if [[ ! -f "$(bs::category_file "$id")" ]]; then
      echo "error: unknown category $id -- run 'categories list' first" >&2
      exit 1
    fi
  done
done

bs::edit_series_matcher_at "$series_id" "$index" "$pattern" "$categories_csv" "$add_categories_csv" "$remove_categories_csv" || exit 1

echo "Matcher $index of series '$series_id' updated."
bs::print_series_matchers_table "$series_id"
