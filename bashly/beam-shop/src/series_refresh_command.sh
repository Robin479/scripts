: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_ids="${args[series_id]:-}"
limit="${args[--limit]:-}"
force="${args[--force]:-}"
# Must be a plain if (see bs::fetch_quiet's doc comment, lib/beam_shop.sh)
# -- a command substitution silently breaks its terminal check.
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

# Fetches every category of series $1, relinks it, then resizes it at all
# of its own preconfigured resolutions (bs::resize_series with no
# width/height override -- falls back to the image_width/_height/_format
# config keys for a series with none). $2/$3 (n/total) are just for this
# function's own "series [n/total]" status prefix -- fetch/relink/resize
# each show their own, more granular status line underneath while this
# one is active (see bs::fetch_category/bs::series_relink/
# bs::resize_series, and bs::status_line for why they don't clobber each
# other). One series' failure at any stage doesn't touch the others; the
# caller tallies ok/fail across calls.
bs::_refresh_one_series() {
  local sid="$1" n="$2" total="$3" categories cid linked resized
  categories="$(bs::series_category_ids "$sid")" || return 1

  echo "=== series $sid [$n/$total] ==="
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    echo "-- category $cid --"
    bs::fetch_category "$cid" "$force" "$sid" "$limit" "$quiet" || return 1
  done <<< "$categories"

  linked="$(bs::series_relink "$sid" "$quiet")" || return 1
  echo "$sid -> relinked ($linked cover(s))"

  resized="$(bs::resize_series "$sid" "" "" "" "$quiet")" || return 1
  echo "$sid -> resized ($resized file(s))"
}

# shellcheck disable=SC2206 # word-splitting is exactly what's wanted -- series_ids is bashly's own space-separated repeatable-arg string, or built the same way just above for the "no ids given" default
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
