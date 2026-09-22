series_dir="$(bs::series_root)"

shopt -s nullglob
files=("$series_dir"/*.json)
shopt -u nullglob

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No series defined yet. Run 'series create <id> --categories <ids>' first."
  exit 0
fi

{
  printf 'id\tname\tcategories\titems\tresolutions\n'
  for f in "${files[@]}"; do
    id="$(jq -r '.series_id' "$f")"
    name="$(jq -r '.name' "$f")"
    cat_count="$(jq -r '.category_ids | length' "$f")"
    res_count="$(jq -r '(.resolutions | length) // 0' "$f")"

    shopt -s nullglob
    product_files=("$(bs::products_dir)"/*.json)
    shopt -u nullglob
    item_count=0
    if [[ "${#product_files[@]}" -gt 0 ]]; then
      item_count="$(jq -s --arg id "$id" '[.[] | select(.series_id == $id and .cover_status == "final")] | length' "${product_files[@]}")"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$cat_count" "$item_count" "$res_count"
  done
} | column -t -s $'\t' -R 3,4,5
