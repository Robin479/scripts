: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_ids="${args[series_id]:-}"
limit="${args[--limit]:-}"
force="${args[--force]:-}"
quiet=""
if bs::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

if [[ -z "$series_ids" ]]; then
  series_ids="$(bs::all_series_ids | tr '\n' ' ')"
  if [[ -z "${series_ids// /}" ]]; then
    echo "No series defined yet."
    exit 0
  fi
fi

bs::offline || bs::init_curl_cmd || exit 1

# Fetches every category of series $1, then resizes it. $2/$3 (n/total)
# are just for the "series [n/total]" status prefix.
bs::_refresh_one_series() {
  local sid="$1" n="$2" total="$3" categories cid resized
  categories="$(bs::series_category_ids "$sid")" || return 1

  echo "=== series $sid [$n/$total] ==="
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    echo "-- category $cid --"
    bs::fetch_category "$cid" "$force" "$limit" "$quiet" || return 1
  done <<< "$categories"

  resized="$(bs::resize_series "$sid" "" "" "" "$quiet")" || return 1
  echo "$sid -> resized ($resized file(s))"
}

# shellcheck disable=SC2206 # intentional word-splitting
series_id_array=($series_ids)
total="${#series_id_array[@]}"
ok=0
fail=0
n=0
for sid in "${series_id_array[@]}"; do
  n=$((n + 1))
  if bs::_refresh_one_series "$sid" "$n" "$total"; then
    ok=$((ok + 1))
  else
    echo "$sid -> refresh failed" >&2
    fail=$((fail + 1))
  fi
done

if [[ "$fail" -gt 0 ]]; then
  echo "Refreshed $ok series, $fail failed."
  exit 1
fi
echo "Refreshed $ok series."
