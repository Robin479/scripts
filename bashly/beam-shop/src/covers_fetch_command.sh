: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
category_ids="${args[category_id]:-}"
series_args="${args[--series]:-}"
all_series="${args[--all-series]:-}"
all_children="${args[--all-children]:-}"
limit="${args[--limit]:-}"
force="${args[--force]:-}"
resize="${args[--resize]:-}"
quiet=""
if bs::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

given=0
[[ -n "$category_ids" ]] && given=$((given + 1))
[[ -n "$series_args" ]] && given=$((given + 1))
[[ -n "$all_series" ]] && given=$((given + 1))

if (( given > 1 )); then
  echo "error: give only one of category id(s), --series, or --all-series" >&2
  exit 1
elif [[ -n "$all_series" ]]; then
  series_args="$(bs::all_series_ids | tr '\n' ' ')"
  if [[ -z "$series_args" ]]; then
    echo "error: no series defined yet (see 'series create')" >&2
    exit 1
  fi
fi

if [[ -n "$series_args" ]]; then
  category_ids=""
  for sid in $series_args; do
    ids="$(bs::series_category_ids "$sid")" || exit 1
    category_ids="$category_ids $(tr '\n' ' ' <<< "$ids")"
  done
  category_ids="$(tr -s ' ' '\n' <<< "$category_ids" | awk '!seen[$0]++' | tr '\n' ' ')"
elif [[ -z "$category_ids" ]]; then
  echo "error: give one or more category ids (see 'categories list'), --series <id> (see 'series list'), or --all-series" >&2
  exit 1
fi

bs::offline || bs::init_curl_cmd || exit 1

targets=""
if [[ -n "$all_children" ]]; then
  for id in $category_ids; do
    children="$(bs::category_children "$id")" || exit 1
    targets="$targets $children"
  done
else
  targets="$category_ids"
fi

for id in $targets; do
  echo "== category $id =="
  bs::fetch_category "$id" "$force" "$limit" "$quiet" || exit 1
done

if [[ -n "$resize" ]]; then
  for sid in $(bs::all_series_ids); do
    resized="$(bs::resize_series "$sid" "" "" "" "$quiet")"
    echo "series $sid resized ($resized file(s))"
  done
fi
