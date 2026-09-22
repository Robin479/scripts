: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"

file="$(bs::require_series_file "$series_id")" || exit 1

jq -r '
  "Id:            " + .series_id,
  "Name:          " + .name,
  "Item pattern:  " + (.item_pattern // "(default: first run of digits)"),
  "Categories:    " + (.category_ids | join(", ")),
  "Resolutions:   " + (if (.resolutions | length) > 0 then (.resolutions | join(", ")) else "(none -- see beam-shop config)" end)
' "$file"

view_dir="$(bs::series_view_dir "$series_id")"
if [[ -d "$view_dir" ]]; then
  shopt -s nullglob
  linked=("$view_dir"/*.json)
  shopt -u nullglob
  echo "Linked covers: ${#linked[@]}"
else
  echo "Linked covers: 0 (run 'series relink $series_id')"
fi
