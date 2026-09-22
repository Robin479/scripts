: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
category_id="${args[category_id]}"

cat_file="$(bs::category_file "$category_id")"
if [[ ! -f "$cat_file" ]]; then
  echo "error: unknown category $category_id -- run 'categories list' first" >&2
  exit 1
fi

jq -r '
  "Id:      " + .category_id,
  "Name:    " + .name,
  "URL:     " + .url,
  "Parent:  " + (.parent_id // "(root)")
' "$cat_file"
