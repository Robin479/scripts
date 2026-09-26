: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"
hide_promoted="${args[--hide-promoted]:-}"

bs::require_series_file "$series_id" > /dev/null || exit 1
if bs::series_is_dirty "$series_id"; then
  echo "* matcher rules changed since the last 'series rebuild' -- these findings may be stale" >&2
fi

findings="$(bs::series_audit "$series_id" "$hide_promoted")" || exit 1
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
  ([.[] | select(.kind == "unsorted")] | length) as $u |
  ([.[] | select(.kind == "ambiguous")] | length) as $a |
  ([.[] | select(.kind == "promoted")] | length) as $pr |
  "\($m) missing (never reached), \($b) broken (no image file, or a linked product'"'"'s fetch failed), \($p) still placeholder, \($u) unsorted (fallback-keyed, awaiting a manual rename), \($a) ambiguous (2+ products currently match the same key -- see '"'"'product_id'"'"' above for which), \($pr) promoted (a manually-pinned product absent from its own item'"'"'s matched list)."
' <<< "$findings_json"
