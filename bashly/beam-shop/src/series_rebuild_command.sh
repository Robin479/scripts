: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_ids="${args[series_id]:-}"
covers_only="${args[--covers-only]:-}"
quiet=""
if bs::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

[[ -z "$series_ids" ]] && series_ids="$(bs::all_series_ids | tr '\n' ' ')"

if [[ -z "${series_ids// /}" ]]; then
  echo "error: no series defined yet (see 'series create')" >&2
  exit 1
fi

# shellcheck disable=SC2086 # word-splitting is exactly what's wanted -- series_ids is bashly's own space-separated repeatable-arg string, or built the same way just above
for id in $series_ids; do
  bs::require_series_file "$id" > /dev/null || exit 1
  if [[ -n "$covers_only" ]]; then
    count="$(bs::series_relink "$id" "$quiet")"
    echo "series $id covers resynced ($count cover(s)) -- classification untouched"
  else
    bs::rebuild_series "$id" "$quiet"
    echo "series $id rebuilt"
  fi
done
