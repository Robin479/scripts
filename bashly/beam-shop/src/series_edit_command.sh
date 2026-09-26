: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"
categories_csv="${args[--categories]:-}"
add_categories_csv="${args[--add-categories]:-}"
remove_categories_csv="${args[--remove-categories]:-}"
resolutions_csv="${args[--resolutions]:-}"
add_resolutions_csv="${args[--add-resolutions]:-}"
remove_resolutions_csv="${args[--remove-resolutions]:-}"
name="${args[--name]:-}"
item_key_format="${args[--item-key-format]:-}"
order="${args[--order]:-auto}"

if [[ -z "$categories_csv" && -z "$add_categories_csv" && -z "$remove_categories_csv" \
      && -z "$resolutions_csv" && -z "$add_resolutions_csv" && -z "$remove_resolutions_csv" \
      && -z "$name" && -z "$item_key_format" ]]; then
  echo "error: give at least one of --categories, --add-categories, --remove-categories, --resolutions, --add-resolutions, --remove-resolutions, --name, --item-key-format" >&2
  exit 1
fi

if [[ -n "$categories_csv" && ( -n "$add_categories_csv" || -n "$remove_categories_csv" ) ]]; then
  echo "error: --categories is a full replacement, mutually exclusive with --add-categories/--remove-categories" >&2
  exit 1
fi

if [[ -n "$resolutions_csv" && ( -n "$add_resolutions_csv" || -n "$remove_resolutions_csv" ) ]]; then
  echo "error: --resolutions is a full replacement, mutually exclusive with --add-resolutions/--remove-resolutions" >&2
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

bs::validate_resize_specs "$resolutions_csv" || exit 1
bs::validate_resize_specs "$add_resolutions_csv" || exit 1

bs::series_edit "$series_id" "$categories_csv" "$add_categories_csv" "$remove_categories_csv" \
  "$resolutions_csv" "$add_resolutions_csv" "$remove_resolutions_csv" \
  "$name" "$item_key_format" "$order" || exit 1

count="$(jq '.category_ids | length' "$(bs::series_file "$series_id")")"
echo "Series '$series_id' updated ($count categor$([[ $count -eq 1 ]] && echo y || echo ies))."
jq -r '
  "Order:       " + (.category_ids | join(", ")),
  "Resolutions: " + (if (.resolutions | length) > 0 then (.resolutions | join(", ")) else "(none -- see beam-shop config)" end)
' "$(bs::series_file "$series_id")"
