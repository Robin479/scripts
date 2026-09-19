: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
update_flag="${args[--update]:-}"
book_ids="${args[book_id]:-}"
blog_ids="${args[--blog]:-}"
challenge_id="${args[--challenge]:-}"
# Must be a plain if (see gr::fetch_quiet's doc comment, lib/goodreads.sh)
# -- a command substitution silently breaks its terminal check, and a
# bare `&&` would trip set -e whenever it's *not* quiet.
quiet=""
if gr::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

# Pre-resolve the curl command here, before gr::run_fetch spawns a
# subshell per item -- gr::init_curl_cmd's memoization flag, set *inside*
# one of those subshells, never survives back to this parent process
# (confirmed: without this, a 3-book fetch re-probed PATH/Docker three
# times over). Skipped under --offline, since nothing here calls curl.
gr::offline || gr::init_curl_cmd || exit 1

if [[ -n "$all" && ( -n "$book_ids" || -n "$blog_ids" || -n "$challenge_id" ) ]]; then
  echo "error: --all and specific book ids (directly, via --blog, or via --challenge) are mutually exclusive" >&2
  exit 1
fi

if [[ -z "$all" && -z "$book_ids" && -z "$blog_ids" && -z "$challenge_id" ]]; then
  echo "error: give one or more book ids, --blog <blog_id>, --challenge <challenge_id>, or --all" >&2
  exit 1
fi

if [[ -n "$challenge_id" ]]; then
  challenge_file="$(gr::require_challenge_file "$challenge_id")" || exit 1
  challenge_blog_ids="$(jq -r '.blogs[]?.blog_id' "$challenge_file")"
  if [[ -z "$challenge_blog_ids" ]]; then
    echo "note: challenge $challenge_id has no linked blog posts" >&2
  fi
  blog_ids="${blog_ids} ${challenge_blog_ids}"
  # A blog id could legitimately be given both directly (--blog) and via
  # --challenge — dedup so gr::blog_json isn't asked for the same post
  # twice in this run (same reasoning as book_ids' own dedup below).
  blog_ids="$(tr -s ' ' '\n' <<< "$blog_ids" | grep -v '^$' | sort -n -u | tr '\n' ' ')"
fi

if [[ -n "$blog_ids" ]]; then
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — blog_ids is bashly's own space-separated repeatable-flag string, or the merged/deduped result of that plus --challenge's own blogs
  for blog_id in $blog_ids; do
    blog_json="$(gr::blog_json "$blog_id")" || {
      echo "error: could not fetch blog post $blog_id" >&2
      exit 1
    }
    blog_book_ids="$(jq -r '[.book_sections[]?.books[]?.book_id] | .[]' <<< "$blog_json")"
    if [[ -z "$blog_book_ids" ]]; then
      echo "note: blog post $blog_id has no books to extract" >&2
    fi
    book_ids="${book_ids} ${blog_book_ids}"
  done

  # Books can legitimately repeat across --blog posts (a --challenge's own
  # linked posts very much included — the whole reason this note calls it
  # out explicitly), or overlap with an explicitly given book_id — dedup
  # so the same id isn't looked at more than once in this run.
  book_ids="$(tr -s ' ' '\n' <<< "$book_ids" | grep -v '^$' | sort -n -u | tr '\n' ' ')"
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

# Force policy for fetch_one, below -- --update always means "force",
# regardless of --all; --all *without* --update means "ttl" (still ask
# about every cached book, but let its own cache TTL decide whether that
# actually turns into a real refetch -- "sync only what's actually gone
# stale", not "force-refresh everything unconditionally", which is what
# this used to do); neither means "" (skip anything already cached, at
# any freshness -- explicit ids' own default).
if [[ -n "$update_flag" ]]; then
  force_policy="force"
elif [[ -n "$all" ]]; then
  force_policy="ttl"
else
  force_policy=""
fi

# Fetches or updates one book -- see gr::run_fetch (lib/goodreads.sh) for
# the calling convention this follows: outcome text on stdout for
# success/skip, nothing on failure (a failure is printed straight to
# stderr instead, right here, after clearing the status line so it can't
# garble together with it). $2 (force) is one of the three policies
# above:
#   ""      -- skipped (return 2) if already cached, at any freshness.
#   "ttl"   -- never skipped outright, but gr::book_json is called
#              plainly (no --force), so *it* decides based on
#              gr::book_fresh whether a real refetch happens; reported as
#              a skip ("already cached (fresh)") when it doesn't, "the
#              real thing" ("refreshed") when it does.
#   "force" -- always gr::book_json --force. "refreshed" if it was
#              already cached going in, "fetched" if this is a genuinely
#              new id (only reachable here via explicit ids + --update,
#              never via --all, which only ever operates on ids that are
#              already cached to begin with).
fetch_one() {
  local id="$1" force="$2" quiet="$3"
  local book_file was_cached=0 was_fresh=1

  book_file="$(gr::book_file "$id")"
  [[ -f "$book_file" ]] || was_cached=1

  if [[ "$force" == "" && "$was_cached" -eq 0 ]]; then
    echo "$id -> already cached"
    return 2
  fi

  # gr::book_json's own stderr (in particular gr::throttle/gr::http_get's
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
    gr::book_fresh "$id" && was_fresh=0
    if gr::book_json "$id" > /dev/null; then
      if [[ "$was_fresh" -eq 0 ]]; then
        echo "$id -> already cached (fresh)"
        return 2
      fi
      echo "$id -> refreshed"
      return 0
    fi
  else
    local force_arg=()
    [[ "$force" == "force" ]] && force_arg=(--force)
    if gr::book_json "$id" "${force_arg[@]}" > /dev/null; then
      if [[ "$was_cached" -eq 0 ]]; then
        echo "$id -> refreshed"
      else
        echo "$id -> fetched"
      fi
      return 0
    fi
  fi

  gr::status_line_clear "$quiet"
  echo "$id -> failed" >&2
  return 1
}

# shellcheck disable=SC2086 # word-splitting is exactly what's wanted — book_ids is either bashly's own space-separated repeatable-arg string, or built the same way just above for --all
gr::run_fetch "$quiet" fetch_one "$force_policy" $book_ids
echo "Fetched/refreshed $GR_FETCH_OK book(s), $GR_FETCH_SKIPPED already cached, $GR_FETCH_FAIL failed."
