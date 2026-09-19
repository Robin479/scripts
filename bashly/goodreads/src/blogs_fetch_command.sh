: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
update_flag="${args[--update]:-}"
blog_ids="${args[blog_id]:-}"
# Must be a plain if (see gr::fetch_quiet's doc comment, lib/goodreads.sh)
# -- a command substitution silently breaks its terminal check, and a
# bare `&&` would trip set -e whenever it's *not* quiet.
quiet=""
if gr::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

# Pre-resolve the curl command here, before gr::run_fetch spawns a
# subshell per item -- see books_fetch_command.sh's own copy of this
# comment for why. Skipped under --offline, since nothing here calls curl.
gr::offline || gr::init_curl_cmd || exit 1

if [[ -n "$all" && -n "$blog_ids" ]]; then
  echo "error: --all and specific blog ids are mutually exclusive" >&2
  exit 1
fi

# gr::blog_json succeeds both when it fetches real content and when it
# just confirms/marks a post permanently removed — distinguish for the
# outcome message. $2 is the wording for a genuine success ("fetched" for
# a post that wasn't cached at all, "refreshed" for one that was).
outcome_text() {
  local post_id="$1" verb="$2"
  if [[ "$(jq -r '.removed_remotely // false' "$(gr::blog_file "$post_id")" 2>/dev/null)" == "true" ]]; then
    echo "$post_id -> confirmed removed remotely"
  else
    echo "$post_id -> $verb"
  fi
}

# Fetches or updates one post -- see gr::run_fetch (lib/goodreads.sh) for
# the calling convention this follows: outcome text on stdout for
# success/skip, nothing on failure (a failure is printed straight to
# stderr instead, right here, after clearing the status line so it can't
# garble together with it). $2 (force) is one of three policies -- the
# same shape books_fetch_command.sh uses for a real TTL, kept consistent
# here even though the blog cache's own TTL is infinite (see "Blog post
# cache" in CLAUDE.md), per explicit direction:
#   ""      -- skipped (return 2) if already cached, unconditionally.
#   "ttl"   -- --all's own default: gr::blog_fresh is just "is this
#              cached at all" (nothing ever goes stale here), so every
#              already-cached post is reported as a skip ("already cached
#              (fresh)") without ever touching the network -- this mode
#              can never actually re-verify an existing post is still
#              there. Run with --update for that.
#   "force" -- always gr::blog_json --force, bypassing gr::blog_fresh
#              entirely -- the only mode that can still detect a post has
#              since been removed remotely.
fetch_one() {
  local id="$1" force="$2" quiet="$3"
  local blog_file was_cached=0

  blog_file="$(gr::blog_file "$id")"
  [[ -f "$blog_file" ]] || was_cached=1

  if [[ "$force" == "" && "$was_cached" -eq 0 ]]; then
    echo "$id -> already cached"
    return 2
  fi

  # gr::blog_json's own stderr (in particular gr::throttle/gr::http_get's
  # "waiting"/"retrying" warnings, which can genuinely take minutes under
  # a real AWS WAF challenge, see CLAUDE.md) is deliberately left flowing
  # straight through here, live, rather than captured and only replayed
  # on failure -- an earlier version captured it, and a slow-but-eventually
  # -successful fetch would silently discard the exact warnings that
  # would have explained the delay, leaving the status line looking
  # frozen with zero indication anything was happening at all. Those
  # warnings clear the status line themselves first (gr::term_clear_line),
  # so they don't garble together with it.
  if [[ "$force" == "ttl" ]]; then
    if gr::blog_fresh "$id"; then
      echo "$id -> already cached (fresh)"
      return 2
    fi
    # Unreachable today -- gr::blog_fresh is trivially true for any
    # cached post -- kept for symmetry/safety should that ever change.
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
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — blog_ids is bashly's own space-separated repeatable-arg string
  gr::run_fetch "$quiet" fetch_one "$explicit_force" $blog_ids
  echo "Fetched/refreshed $GR_FETCH_OK blog post(s), $GR_FETCH_SKIPPED already cached, $GR_FETCH_FAIL failed."
  exit 0
fi

# No specific ids: plain `fetch` discovers only; `--all` also checks
# everything already cached (see fetch_one's "ttl"/"force" split above).
blog_dir="$(gr::blog_dir)"
mkdir -p "$blog_dir"

# Real on-disk cached ids, to diff discovery's result against (it no longer
# filters against the cache itself). One line per append — a literal split
# across two source lines gets corrupted by bashly's embedding step (see
# CLAUDE.md).
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
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — new_ids is a newline-separated id list; force="" since these are guaranteed not cached yet
  gr::run_fetch "$quiet" fetch_one "" $new_ids
  echo "Fetched $GR_FETCH_OK new blog post(s), $GR_FETCH_FAIL failed."
fi

if [[ -n "$all" ]]; then
  echo
  if [[ -z "$cached_ids" ]]; then
    echo "No cached blog posts yet."
  else
    echo "Checking already-cached posts..."
    refresh_force="ttl"
    [[ -n "$update_flag" ]] && refresh_force="force"
    # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — cached_ids is the newline-separated id list built above
    gr::run_fetch "$quiet" fetch_one "$refresh_force" $cached_ids
    echo "Fetched/refreshed $GR_FETCH_OK blog post(s), $GR_FETCH_SKIPPED already cached, $GR_FETCH_FAIL failed."
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
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted, one id per printf call
  printf '  %s\n' $missing_ids
fi
