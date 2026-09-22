: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
series_ids="${args[series_id]:-}"

if [[ -n "$all" && -n "$series_ids" ]]; then
  echo "error: --all and specific series ids are mutually exclusive" >&2
  exit 1
fi

if [[ -z "$all" && -z "$series_ids" ]]; then
  echo "error: give one or more series ids, or --all" >&2
  exit 1
fi

if [[ -n "$all" ]]; then
  # shellcheck disable=SC2207 # bs::all_series_ids' own output is a plain newline-separated list, one id per line, none of them containing whitespace
  ids=($(bs::all_series_ids))
  if [[ "${#ids[@]}" -eq 0 ]]; then
    echo "No series to remove."
    exit 0
  fi
  series_ids="${ids[*]}"
fi

ok=0
fail=0
# shellcheck disable=SC2086 # word-splitting is exactly what's wanted -- series_ids is either bashly's own space-separated repeatable-arg string, or built the same way just above for --all
for id in $series_ids; do
  if bs::series_remove "$id"; then
    echo "$id -> removed"
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

if [[ "$fail" -gt 0 ]]; then
  echo "Removed $ok series, $fail not found."
  exit 1
fi
echo "Removed $ok series."
