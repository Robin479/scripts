: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
parent_id="${args[parent_id]:-}"
refresh="${args[--refresh]:-}"

bs::offline || bs::init_curl_cmd || exit 1

ids="$(bs::category_children "$parent_id" "$refresh")" || exit 1

if [[ -z "$ids" ]]; then
  echo "No categories found."
  exit 0
fi

{
  printf 'id\tname\turl\n'
  for id in $ids; do
    cat_file="$(bs::category_file "$id")"
    name="$(jq -r '.name' "$cat_file")"
    url="$(jq -r '.url' "$cat_file")"
    printf '%s\t%s\t%s\n' "$id" "$name" "$url"
  done
} | column -t -s $'\t' -R 1
