: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
update_flag="${args[--update]:-}"
book_ids="${args[book_id]:-}"
blog_ids="${args[--blog]:-}"
challenge_id="${args[--challenge]:-}"
# Plain if: $(...) would break gr::fetch_quiet's tty check, `&&` trips set -e.
quiet=""
if gr::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

# Resolve curl before gr::run_fetch's per-item subshells (memoization wouldn't survive them).
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
  # Dedup: a post may come both via --blog and via --challenge.
  blog_ids="$(tr -s ' ' '\n' <<< "$blog_ids" | grep -v '^$' | sort -n -u | tr '\n' ' ')"
fi

if [[ -n "$blog_ids" ]]; then
  # shellcheck disable=SC2086 # intentional word-splitting of the id list
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

  # Dedup: books repeat across posts and may overlap explicit ids.
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

if [[ -n "$update_flag" ]]; then
  force_policy="force"
elif [[ -n "$all" ]]; then
  force_policy="ttl"
else
  force_policy=""
fi

# gr::run_fetch callback: outcome on stdout, return 0/1/2 = ok/failed/skipped.
# $2 (force): "" skip if cached; "ttl" let gr::book_json's TTL decide;
# "force" always refetch.
fetch_one() {
  local id="$1" force="$2" quiet="$3"
  local book_file was_cached=0 was_fresh=1

  book_file="$(gr::book_file "$id")"
  [[ -f "$book_file" ]] || was_cached=1

  if [[ "$force" == "" && "$was_cached" -eq 0 ]]; then
    echo "$id -> already cached"
    return 2
  fi

  # stderr is deliberately not captured, so wait/retry warnings show live.
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

# shellcheck disable=SC2086 # intentional word-splitting of the id list
gr::run_fetch "$quiet" fetch_one "$force_policy" $book_ids
echo "Fetched/refreshed $GR_FETCH_OK book(s), $GR_FETCH_SKIPPED already cached, $GR_FETCH_FAIL failed${GR_FETCH_ABORTED:+, $GR_FETCH_ABORTED not attempted}."
[[ -z "$GR_FETCH_ABORTED" ]] || exit 1
