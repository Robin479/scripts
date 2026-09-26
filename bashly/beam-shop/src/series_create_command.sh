: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"
categories_csv="${args[--categories]}"
resolutions_csv="${args[--resolutions]:-}"
name="${args[--name]:-}"
item_key_format="${args[--item-key-format]:-}"
order="${args[--order]:-auto}"

if [[ "$series_id" == */* ]]; then
  echo "error: series_id must not contain '/': $series_id" >&2
  exit 1
fi

if [[ -f "$(bs::series_file "$series_id")" ]]; then
  echo "error: series '$series_id' already exists -- use 'series edit' to change it" >&2
  exit 1
fi

IFS=',' read -r -a ids <<< "$categories_csv"
for id in "${ids[@]}"; do
  if [[ ! -f "$(bs::category_file "$id")" ]]; then
    echo "error: unknown category $id -- run 'categories list' first" >&2
    exit 1
  fi
done

bs::validate_resize_specs "$resolutions_csv" || exit 1

bs::series_create "$series_id" "$categories_csv" "$resolutions_csv" "$name" "$item_key_format" "$order" || exit 1

count="$(jq '.category_ids | length' "$(bs::series_file "$series_id")")"
echo "Series '$series_id' created with $count categor$([[ $count -eq 1 ]] && echo y || echo ies)."
jq -r '
  "Order:       " + (.category_ids | join(", ")),
  "Resolutions: " + (if (.resolutions | length) > 0 then (.resolutions | join(", ")) else "(none -- see beam-shop config)" end),
  "Matchers:    none yet -- run \"series matcher add\" to define membership"
' "$(bs::series_file "$series_id")"
