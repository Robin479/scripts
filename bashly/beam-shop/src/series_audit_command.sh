: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"

findings="$(bs::series_audit "$series_id")" || exit 1
if [[ -z "$findings" ]]; then
  echo "No issues found for series '$series_id'."
  exit 0
fi

findings_json="$(jq -s 'sort_by(.item_number)' <<< "$findings")"

{
  printf 'item\tissue\tproduct_id\ttitle\n'
  jq -r '.[] | [(.item_number // "?"), .kind, (.product_id // "-"), (.title // "-")] | @tsv' <<< "$findings_json"
} | column -t -s $'\t'

echo
jq -r '
  ([.[] | select(.kind == "missing")] | length) as $m |
  ([.[] | select(.kind == "broken")] | length) as $b |
  ([.[] | select(.kind == "placeholder")] | length) as $p |
  "\($m) missing (never reached), \($b) broken (failed download or a final record with no image file), \($p) still placeholder."
' <<< "$findings_json"
