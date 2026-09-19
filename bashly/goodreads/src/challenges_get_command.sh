: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[challenge_id]:-}"
json="${args[--json]:-}"

# No id given: default to the next challenge to actually finish (ongoing
# or still-planned, whichever ends soonest) if one exists; otherwise the
# most recently ended one; otherwise there's nothing to show at all.
if [[ -z "$id" ]]; then
  next="$(gr::next_ending_challenge "$(date +%Y-%m-%d)")"
  if [[ -n "$next" ]]; then
    IFS=$'\t' read -r id _ _ <<<"$next"
  else
    latest="$(gr::latest_challenge)"
    if [[ -n "$latest" ]]; then
      IFS=$'\t' read -r id _ _ <<<"$latest"
    else
      echo "error: no challenges yet. Run 'goodreads challenges create' to add one." >&2
      exit 1
    fi
  fi
fi

file="$(gr::require_challenge_file "$id")" || exit 1

if [[ -n "$json" ]]; then
  cat "$file"
  exit 0
fi

today="$(date +%Y-%m-%d)"

# "$GR_CHALLENGE_STATUS_JQ_DEF"'...' concatenates into one jq argument —
# see GR_CHALLENGE_STATUS_JQ_DEF in lib/goodreads_challenges.sh.
result="$(jq --arg today "$today" "$GR_CHALLENGE_STATUS_JQ_DEF"'
  {
    meta: [
      (.title // "(untitled)"),
      "\(.start) to \(.end) (\(challenge_status($today)))"
    ],
    blogs: [(.blogs // [])[] | [
      .blog_id,
      (.name // "(unnamed)"),
      ("https://www.goodreads.com/blog/show/" + .blog_id)
    ] | @tsv],
    badges: [(.count_badges // [])[] | [
      (.count | tostring),
      (.name // "(unnamed)")
    ] | @tsv]
  }
' "$file")"

jq -r '.meta[]' <<< "$result"

blogs_count="$(jq -r '.blogs | length' <<< "$result")"
if [[ "$blogs_count" -gt 0 ]]; then
  echo
  echo "Blogs ($blogs_count):"
  jq -r '.blogs[]' <<< "$result" | column -t -s $'\t' -R 1 | sed 's/^/  /'
fi

badges_count="$(jq -r '.badges | length' <<< "$result")"
if [[ "$badges_count" -gt 0 ]]; then
  echo
  echo "Badges ($badges_count):"
  jq -r '.badges[]' <<< "$result" | column -t -s $'\t' -R 1 | sed 's/^/  /'
fi
