: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
blog_ids="${args[blog_id]:-}"
all="${args[--all]:-}"
since_raw="${args[--since]:-}"
until_raw="${args[--until]:-}"
reverse="${args[--reverse]:-}"
limit_raw="${args[--limit]:-}"

if [[ -n "$all" && ( -n "$since_raw" || -n "$until_raw" || -n "$limit_raw" ) ]]; then
  echo "error: --all is mutually exclusive with --since/--until/--limit" >&2
  exit 1
fi

limit=15
if [[ -n "$limit_raw" ]]; then
  if ! [[ "$limit_raw" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --limit must be a positive integer: $limit_raw" >&2
    exit 1
  fi
  limit="$limit_raw"
fi

# date -d parsing, same as gr::refresh_blog's published-date parsing.
since=""
if [[ -n "$since_raw" ]]; then
  if ! since="$(date -d "$since_raw" +%Y-%m-%d 2>/dev/null)"; then
    echo "error: could not parse --since date: $since_raw" >&2
    exit 1
  fi
fi

until_date=""
if [[ -n "$until_raw" ]]; then
  if ! until_date="$(date -d "$until_raw" +%Y-%m-%d 2>/dev/null)"; then
    echo "error: could not parse --until date: $until_raw" >&2
    exit 1
  fi
fi

if [[ -n "$since" && -n "$until_date" && -n "$limit_raw" ]]; then
  echo "error: --limit has no effect once both --since and --until are given (every post in that range is shown) — omit it" >&2
  exit 1
fi

if [[ -n "$since" && -n "$until_date" && "$until_date" < "$since" ]]; then
  echo "error: --until ($until_date) is before --since ($since)" >&2
  exit 1
fi

blog_dir="$(gr::blog_dir)"

if [[ ! -d "$blog_dir" ]] || [[ -z "$(ls -A "$blog_dir" 2>/dev/null)" ]]; then
  echo "No cached blog posts yet. Run 'goodreads blogs fetch <blog_id>' to fetch one."
  exit 0
fi

files=()
if [[ -n "$blog_ids" ]]; then
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — blog_ids is bashly's own space-separated repeatable-arg string
  for id in $blog_ids; do
    file="$(gr::blog_file "$id")"
    if [[ -f "$file" ]]; then
      files+=("$file")
    else
      echo "$id -> not cached" >&2
    fi
  done
else
  for file in "$blog_dir"/*.json; do
    [[ -e "$file" ]] && files+=("$file")
  done
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No cached blog posts match those filters."
  exit 0
fi

# --all, explicit ids, or both --since+--until: no cap.
bypass_limit=false
[[ -n "$all" || -n "$blog_ids" || ( -n "$since" && -n "$until_date" ) ]] && bypass_limit=true

reverse_flag=false
[[ -n "$reverse" ]] && reverse_flag=true

# "$GR_CHALLENGE_JQ_DEFS"'...' concatenates into one jq argument — see
# GR_CHALLENGE_JQ_DEFS in lib/goodreads_blogs.sh.
result="$(cat "${files[@]}" | jq -s \
  --arg since "$since" \
  --arg until "$until_date" \
  --argjson bypass_limit "$bypass_limit" \
  --argjson limit "$limit" \
  --argjson reverse "$reverse_flag" \
  "$GR_CHALLENGE_JQ_DEFS"'
    def in_range: (.published != null)
      and ($since == "" or .published >= $since)
      and ($until == "" or .published <= $until);

    # jq has no printf-style decimal formatting; round to cents and
    # zero-pad the fractional part back to two digits.
    def fmt2dp:
      (. * 100 | round) as $cents
      | ($cents / 100 | floor) as $whole
      | ($cents - ($whole * 100)) as $frac
      | "\($whole).\(if $frac < 10 then "0" else "" end)\($frac)";

    (if ($since != "" or $until != "") then map(select(in_range)) else . end)
    | (sort_by(.published // "0000-00-00") | reverse) as $sorted
    | ($sorted | length) as $total
    # --since only: cap keeps the oldest matching (closest to --since).
    | (
        if $bypass_limit then $sorted
        elif $since != "" then ($sorted | reverse | .[0:$limit] | reverse)
        else $sorted[0:$limit]
        end
      ) as $capped
    | (if $reverse then ($capped | reverse) else $capped end) as $display
    | {
        total: $total,
        lines: [$display[] | [
          .blog_id,
          (.published // "?"),
          ((.title // "(no title)") + (if .removed_remotely then " [removed remotely]" else "" end)),
          ([.book_sections[]?.books[]?] | length | tostring),
          ((.challenge_potential // 0 | fmt2dp) + " " + gr_challenge_marker),
          ("https://www.goodreads.com/blog/show/" + .blog_id)
        ] | @tsv]
      }
  ')"

total="$(jq -r '.total' <<< "$result")"

if [[ "$total" -eq 0 ]]; then
  echo "No cached blog posts match those filters."
  exit 0
fi

# challenge: "<potential> <marker>" — marker is °/*/?/space for
# explicitly-not/explicitly-yes/machine-guessed/neither (blogs challenge).
{
  printf 'id\tpublished\ttitle\tbooks\tchallenge\turl\n'
  jq -r '.lines[]' <<< "$result"
} | column -t -s $'\t' -R 1,4

if [[ "$bypass_limit" == false && "$total" -gt "$limit" ]]; then
  echo
  if [[ -n "$since" ]]; then
    echo "Showing the $limit oldest of $total matching post(s) — pass --all to see the rest."
  else
    echo "Showing the $limit most recent of $total matching post(s) — pass --all to see the rest."
  fi
fi
