: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
book_ids="${args[book_id]:-}"

if [[ -n "$all" && -n "$book_ids" ]]; then
  echo "error: --all and specific book ids are mutually exclusive" >&2
  exit 1
fi

if [[ -z "$all" && -z "$book_ids" ]]; then
  echo "error: give one or more book ids, or --all" >&2
  exit 1
fi

if [[ -n "$all" ]]; then
  book_dir="$(gr::book_dir)"
  ids=()
  for file in "$book_dir"/*.json; do
    [[ -e "$file" ]] && ids+=("$(basename "$file" .json)")
  done
  if [[ "${#ids[@]}" -eq 0 ]]; then
    echo "No cached books yet."
    exit 0
  fi
  book_ids="${ids[*]}"
fi

ok=0
fail=0
# shellcheck disable=SC2086 # word-splitting is exactly what's wanted — book_ids is either bashly's own space-separated repeatable-arg string, or built the same way just above for --all
for id in $book_ids; do
  if gr::book_json "$id" --force > /dev/null; then
    echo "$id -> refreshed"
    ok=$((ok + 1))
  else
    echo "$id -> failed" >&2
    fail=$((fail + 1))
  fi
done

echo "Refreshed $ok book(s), $fail failed."
