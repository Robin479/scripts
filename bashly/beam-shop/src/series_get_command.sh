: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"

file="$(bs::require_series_file "$series_id")" || exit 1

if bs::series_is_dirty "$series_id"; then
  echo "* matcher rules changed since the last 'series rebuild' -- current classification may be stale"
fi

jq -r '
  "Id:              " + .series_id,
  "Name:            " + .name,
  "Item key format: " + (.item_key_format // "(default: \"%d\")"),
  "Categories:      " + (.category_ids | join(", ")),
  "Resolutions:     " + (if (.resolutions | length) > 0 then (.resolutions | join(", ")) else "(none -- see beam-shop config)" end)
' "$file"

matcher_count="$(jq '(.matchers // []) | length' "$file")"
echo
if [[ "$matcher_count" -gt 0 ]]; then
  echo "Matchers:"
  {
    printf 'index\tpattern\tcategories\n'
    bs::series_matchers "$series_id" | jq -r '[.index, .pattern, ((.categories // []) | join(","))] | @tsv'
  } | column -t -s $'\t' -R 1 | sed 's/^/  /'
else
  echo "Matchers: none yet -- run 'series matcher add' to add one"
fi

view_dir="$(bs::series_dir "$series_id")"
shopt -s nullglob
linked=("$view_dir"/*.json)
shopt -u nullglob
count=0
for f in "${linked[@]}"; do
  [[ "$(basename "$f")" == meta.json ]] || count=$((count + 1))
done
echo "Linked covers: $count"
