: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
blog_ids="${args[blog_id]:-}"

if [[ -n "$all" && -n "$blog_ids" ]]; then
  echo "error: --all and specific blog ids are mutually exclusive" >&2
  exit 1
fi

if [[ -z "$all" && -z "$blog_ids" ]]; then
  echo "error: give one or more blog ids, or --all" >&2
  exit 1
fi

remove_one() {
  local id="$1"
  local file
  file="$(gr::blog_file "$id")"
  if [[ ! -f "$file" ]]; then
    echo "$id -> not cached" >&2
    return 1
  fi
  rm -f "$file"
  echo "$id -> removed"
}

if [[ -n "$all" ]]; then
  blog_dir="$(gr::blog_dir)"
  ids=()
  for file in "$blog_dir"/*.json; do
    [[ -e "$file" ]] && ids+=("$(basename "$file" .json)")
  done
  if [[ "${#ids[@]}" -eq 0 ]]; then
    echo "No cached blog posts to remove."
    exit 0
  fi
  blog_ids="${ids[*]}"
fi

ok=0
fail=0
# shellcheck disable=SC2086 # word-splitting is exactly what's wanted — blog_ids is either bashly's own space-separated repeatable-arg string, or built the same way just above for --all
for id in $blog_ids; do
  if remove_one "$id"; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

if [[ "$fail" -gt 0 ]]; then
  echo "Removed $ok blog post(s), $fail not found."
  exit 1
fi
echo "Removed $ok blog post(s)."
