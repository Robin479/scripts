: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_ids="${args[series_id]:-}"
# No --batch flag on this command -- just the automatic terminal check
# (see bs::fetch_quiet); must be a plain if, not a command substitution.
quiet=""
if bs::fetch_quiet ""; then
  quiet=1
fi

if [[ -z "$series_ids" ]]; then
  shopt -s nullglob
  files=("$(bs::series_root)"/*.json)
  shopt -u nullglob
  ids=()
  for f in "${files[@]}"; do
    ids+=("$(jq -r '.series_id' "$f")")
  done
  series_ids="${ids[*]}"
fi

if [[ -z "$series_ids" ]]; then
  echo "No series defined yet."
  exit 0
fi

# shellcheck disable=SC2086 # word-splitting is exactly what's wanted — series_ids is bashly's own space-separated repeatable-arg string, or built the same way just above
for id in $series_ids; do
  count="$(bs::series_relink "$id" "$quiet")" || exit 1
  echo "$id -> $count cover(s) linked"
done
