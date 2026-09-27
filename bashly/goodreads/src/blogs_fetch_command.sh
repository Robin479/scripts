: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
update_flag="${args[--update]:-}"
blog_ids="${args[blog_id]:-}"
# Plain if: $(...) would break gr::fetch_quiet's tty check, `&&` trips set -e.
quiet=""
if gr::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

# Resolve curl before gr::run_fetch's per-item subshells (memoization wouldn't survive them).
gr::offline || gr::init_curl_cmd || exit 1

if [[ -n "$all" && -n "$blog_ids" ]]; then
  echo "error: --all and specific blog ids are mutually exclusive" >&2
  exit 1
fi

# gr::blog_json also succeeds for a post confirmed removed; $2 is the wording otherwise.
outcome_text() {
  local post_id="$1" verb="$2"
  if [[ "$(jq -r '.removed_remotely // false' "$(gr::blog_file "$post_id")" 2>/dev/null)" == "true" ]]; then
    echo "$post_id -> confirmed removed remotely"
  else
    echo "$post_id -> $verb"
  fi
}

# gr::run_fetch callback: outcome on stdout, return 0/1/2 = ok/failed/skipped.
# $2 (force): "" skip if cached; "ttl" skip if fresh (always, blog TTL is
# infinite); "force" always refetch (only way to detect remote removal).
fetch_one() {
  local id="$1" force="$2" quiet="$3"
  local blog_file was_cached=0

  blog_file="$(gr::blog_file "$id")"
  [[ -f "$blog_file" ]] || was_cached=1

  if [[ "$force" == "" && "$was_cached" -eq 0 ]]; then
    echo "$id -> already cached"
    return 2
  fi

  # stderr is deliberately not captured, so wait/retry warnings show live.
  if [[ "$force" == "ttl" ]]; then
    if gr::blog_fresh "$id"; then
      echo "$id -> already cached (fresh)"
      return 2
    fi
    # Currently unreachable (gr::blog_fresh is true for any cached post).
    if gr::blog_json "$id" > /dev/null; then
      outcome_text "$id" "refreshed"
      return 0
    fi
  else
    local force_arg=()
    [[ "$force" == "force" ]] && force_arg=(--force)
    if gr::blog_json "$id" "${force_arg[@]}" > /dev/null; then
      if [[ "$was_cached" -eq 0 ]]; then
        outcome_text "$id" "refreshed"
      else
        outcome_text "$id" "fetched"
      fi
      return 0
    fi
  fi

  gr::status_line_clear "$quiet"
  echo "$id -> failed" >&2
  return 1
}

if [[ -n "$blog_ids" ]]; then
  explicit_force=""
  [[ -n "$update_flag" ]] && explicit_force="force"
  # shellcheck disable=SC2086 # intentional word-splitting of bashly's repeatable arg
  gr::run_fetch "$quiet" fetch_one "$explicit_force" $blog_ids
  echo "Fetched/refreshed $GR_FETCH_OK blog post(s), $GR_FETCH_SKIPPED already cached, $GR_FETCH_FAIL failed${GR_FETCH_ABORTED:+, $GR_FETCH_ABORTED not attempted}."
  [[ -z "$GR_FETCH_ABORTED" ]] || exit 1
  exit 0
fi

# No ids: discover new posts; --all also re-checks everything cached.
blog_dir="$(gr::blog_dir)"
mkdir -p "$blog_dir"

# Cached ids, to diff discovery against. $'\n' join, not a literal newline (bashly re-indents).
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
  # --full: complete scan, needed for the "missing" report below.
  catalog_ids="$(gr::discover_blog_ids --full)" || exit 1
  new_ids="$(comm -23 <(echo "$catalog_ids") <(echo "$cached_ids"))"
  missing_ids="$(comm -23 <(echo "$cached_ids") <(echo "$catalog_ids"))"
else
  # Stops at the discovery marker, so incomplete: no missing report.
  scanned_ids="$(gr::discover_blog_ids)" || exit 1
  new_ids="$(comm -23 <(sort -n -u <<< "$scanned_ids") <(echo "$cached_ids"))"
  missing_ids=""
fi

if [[ -z "$new_ids" ]]; then
  echo "No new blog posts found — already have everything currently listed."
else
  # shellcheck disable=SC2086 # intentional word-splitting of the id list
  gr::run_fetch "$quiet" fetch_one "" $new_ids
  echo "Fetched $GR_FETCH_OK new blog post(s), $GR_FETCH_FAIL failed${GR_FETCH_ABORTED:+, $GR_FETCH_ABORTED not attempted}."
  # Stopped early: re-checking cached posts (--all) would hit the same problem.
  [[ -z "$GR_FETCH_ABORTED" ]] || exit 1
fi

if [[ -n "$all" ]]; then
  echo
  if [[ -z "$cached_ids" ]]; then
    echo "No cached blog posts yet."
  else
    echo "Checking already-cached posts..."
    refresh_force="ttl"
    [[ -n "$update_flag" ]] && refresh_force="force"
    # shellcheck disable=SC2086 # intentional word-splitting of the id list
    gr::run_fetch "$quiet" fetch_one "$refresh_force" $cached_ids
    echo "Fetched/refreshed $GR_FETCH_OK blog post(s), $GR_FETCH_SKIPPED already cached, $GR_FETCH_FAIL failed${GR_FETCH_ABORTED:+, $GR_FETCH_ABORTED not attempted}."
    [[ -z "$GR_FETCH_ABORTED" ]] || exit 1
  fi
fi

if [[ -n "$missing_ids" ]]; then
  count="$(wc -l <<< "$missing_ids")"
  echo
  echo "$count cached post(s) no longer appear in the current listing."
  echo "That doesn't necessarily mean they were deleted — the listing is"
  echo "recency-ordered, so a post can simply age off the visible page range"
  echo "without being gone. Run 'goodreads blogs fetch <blog_id> --update' on"
  echo "one to actually confirm (a real 404 gets recorded as removed_remotely;"
  echo "still being there just refreshes it normally):"
  # shellcheck disable=SC2086 # intentional word-splitting, one id per line
  printf '  %s\n' $missing_ids
fi
