: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
blog_ids="${args[blog_id]:-}"

if [[ -n "$all" && -n "$blog_ids" ]]; then
  echo "error: --all and specific blog ids are mutually exclusive" >&2
  exit 1
fi

# gr::blog_json succeeds both when it fetches real content and when it
# just confirms/marks a post permanently removed — distinguish for the
# outcome message.
report_outcome() {
  local post_id="$1"
  if [[ "$(jq -r '.removed_remotely // false' "$(gr::blog_file "$post_id")" 2>/dev/null)" == "true" ]]; then
    echo "$post_id -> confirmed removed remotely"
  else
    echo "$post_id -> refreshed"
  fi
}

# Shared by --all and an explicit id list.
force_refresh_many() {
  if [[ "$#" -eq 0 ]]; then
    echo "No cached blog posts yet."
    return 0
  fi

  local ok=0 fail=0 id
  for id in "$@"; do
    if gr::blog_json "$id" --force > /dev/null; then
      report_outcome "$id"
      ok=$((ok + 1))
    else
      echo "$id -> failed" >&2
      fail=$((fail + 1))
    fi
  done
  echo "Refreshed $ok blog post(s), $fail failed."
}

if [[ -n "$blog_ids" ]]; then
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — blog_ids is bashly's own space-separated repeatable-arg string
  force_refresh_many $blog_ids
  exit 0
fi

# No specific ids: plain `update` discovers only; `--all` also
# force-refreshes everything already cached.
blog_dir="$(gr::blog_dir)"
mkdir -p "$blog_dir"

# Real on-disk cached ids — needed to diff discovery's result against, since
# gr::discover_blog_ids no longer filters against the cache itself.
#
# One line per append — a string literal split across two physical source
# lines in a *_command.sh file gets corrupted by bashly's command-embedding
# step (adds a stray indent into the value itself; see CLAUDE.md).
cached_ids=""
for file in "$blog_dir"/*.json; do
  if [[ -e "$file" ]]; then
    id="$(basename "$file" .json)"
    cached_ids="${cached_ids}${cached_ids:+$'\n'}${id}"
  fi
done
cached_ids="$(sort -n -u <<< "$cached_ids")"

echo "Scanning the goodreads.com blog listing..."

if [[ -n "$all" ]]; then
  # --full: a genuine complete scan, needed for the "missing" report below.
  catalog_ids="$(gr::discover_blog_ids --full)" || exit 1
  new_ids="$(comm -23 <(echo "$catalog_ids") <(echo "$cached_ids"))"
  missing_ids="$(comm -23 <(echo "$cached_ids") <(echo "$catalog_ids"))"
else
  # Short-circuits at the discovery marker (see lib/goodreads_blogs.sh) —
  # not guaranteed complete, so no missing_ids report on this path.
  scanned_ids="$(gr::discover_blog_ids)" || exit 1
  new_ids="$(comm -23 <(sort -n -u <<< "$scanned_ids") <(echo "$cached_ids"))"
  missing_ids=""
fi

if [[ -z "$new_ids" ]]; then
  echo "No new blog posts found — already have everything currently listed."
else
  ok=0
  fail=0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if gr::blog_json "$id" > /dev/null; then
      echo "$id -> fetched"
      ok=$((ok + 1))
    else
      echo "$id -> failed" >&2
      fail=$((fail + 1))
    fi
  done <<< "$new_ids"
  echo "Fetched $ok new blog post(s), $fail failed."
fi

if [[ -n "$all" ]]; then
  echo
  echo "Force-refreshing every already-cached post..."
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — cached_ids is the newline-separated id list built above
  force_refresh_many $cached_ids
fi

if [[ -n "$missing_ids" ]]; then
  count="$(wc -l <<< "$missing_ids")"
  echo
  echo "$count cached post(s) no longer appear in the current listing."
  echo "That doesn't necessarily mean they were deleted — the listing is"
  echo "recency-ordered, so a post can simply age off the visible page range"
  echo "without being gone. Run 'goodreads blogs update <blog_id>' on one to"
  echo "actually confirm (a real 404 gets recorded as removed_remotely; still"
  echo "being there just refreshes it normally):"
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted, one id per printf call
  printf '  %s\n' $missing_ids
fi
