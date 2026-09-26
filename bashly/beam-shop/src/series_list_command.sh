# shellcheck disable=SC2207 # bs::all_series_ids' own output is a plain newline-separated list, one id per line, none of them containing whitespace
ids=($(bs::all_series_ids))

if [[ "${#ids[@]}" -eq 0 ]]; then
  echo "No series defined yet. Run 'series create <id> --categories <ids>' first."
  exit 0
fi

any_dirty=""
for id in "${ids[@]}"; do
  bs::series_is_dirty "$id" && any_dirty=1
done

{
  printf 'id\tname\tcategories\titems\tresolutions\n'
  for id in "${ids[@]}"; do
    f="$(bs::series_file "$id")"
    name="$(jq -r '.name' "$f")"
    cat_count="$(jq -r '.category_ids | length' "$f")"
    res_count="$(jq -r '(.resolutions | length) // 0' "$f")"

    display_id="$id"
    bs::series_is_dirty "$id" && display_id="${id}*"

    # excludes meta.json; dot-fallback items aren't matched by this glob either
    shopt -s nullglob
    item_files=("$(bs::series_dir "$id")"/*.json)
    shopt -u nullglob
    item_count=0
    for itf in "${item_files[@]}"; do
      [[ "$(basename "$itf")" == meta.json ]] || item_count=$((item_count + 1))
    done

    printf '%s\t%s\t%s\t%s\t%s\n' "$display_id" "$name" "$cat_count" "$item_count" "$res_count"
  done
} | column -t -s $'\t' -R 3,4,5

[[ -n "$any_dirty" ]] && echo "(* -- matcher rules changed since the last 'series rebuild')"
