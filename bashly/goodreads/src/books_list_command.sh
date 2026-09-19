: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
book_ids="${args[book_id]:-}"
limit_raw="${args[--limit]:-}"

limit=""
if [[ -n "$limit_raw" ]]; then
  if ! [[ "$limit_raw" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --limit must be a positive integer: $limit_raw" >&2
    exit 1
  fi
  limit="$limit_raw"
fi

book_dir="$(gr::book_dir)"

if [[ ! -d "$book_dir" ]] || [[ -z "$(ls -A "$book_dir" 2>/dev/null)" ]]; then
  echo "No cached books yet. Run 'goodreads books fetch <book_id>' to fetch one."
  exit 0
fi

files=()
if [[ -n "$book_ids" ]]; then
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — book_ids is bashly's own space-separated repeatable-arg string
  for id in $book_ids; do
    file="$(gr::book_file "$id")"
    if [[ -f "$file" ]]; then
      files+=("$file")
    else
      echo "$id -> not cached" >&2
    fi
  done
else
  for file in "$book_dir"/*.json; do
    [[ -e "$file" ]] && files+=("$file")
  done
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No cached books match those filters."
  exit 0
fi

result="$(cat "${files[@]}" | jq -s --argjson limit "${limit:-0}" '
  # Truncates to at most n characters, replacing the tail with a single "…"
  # (not "..."; one character, so a truncated string is never longer than n)
  # once the untruncated value would exceed it.
  def trunc(n): if (length > n) then (.[0:(n - 1)] + "…") else . end;

  # Heuristic, not a real parse: "Title: tag-line" gets the tag-line
  # dropped only when the whole title exceeds 30 chars AND the part before
  # the (first) colon is shorter than the part after (a real tag-line is
  # normally the longer half). Full title always available via `books get`.
  def strip_tagline:
    . as $title
    | ($title | index(":")) as $i
    | if $i == null or ($title | length) <= 30 then $title
      else
        ($title[0:$i] | sub("\\s+$"; "")) as $before
        | ($title[($i + 1):] | sub("^\\s+"; "")) as $after
        | if ($before | length) < ($after | length) then $before else $title end
      end;

  # Truncates joined author names to at most n characters, cutting at a
  # name boundary rather than mid-name whenever possible. Falls back to a
  # mid-name cut only when the first name alone already exceeds n.
  def trunc_authors(n):
    . as $names
    | (join(", ")) as $full
    | if ($full | length) <= n then $full
      elif (($names[0] // "") | length) > n then ($full | trunc(n))
      else
        ([range(1; ($names | length) + 1) | $names[0:.] | join(", ") | select(length <= n)] | last) as $best
        | $best + ", …"
      end;

  (sort_by((.title // .name // "") | ascii_downcase)) as $sorted
  | ($sorted | length) as $total
  | (if $limit > 0 then $sorted[0:$limit] else $sorted end) as $display
  | {
      total: $total,
      lines: [$display[] | [
        .book_id,
        (.published // "?"),
        ([.contributors[]?.name] | trunc_authors(30)),
        ((.title // .name // "(no title)") | strip_tagline | trunc(60)),
        (.numberOfPages // "?" | tostring),
        (if (.aggregateRating.ratingValue // null) != null then "\(.aggregateRating.ratingValue)" else "?" end),
        ("https://goodreads.com/book/show/" + .book_id)
      ] | @tsv]
    }
')"

total="$(jq -r '.total' <<< "$result")"

if [[ "$total" -eq 0 ]]; then
  echo "No cached books match those filters."
  exit 0
fi

{
  printf 'id\tpublished\tauthor(s)\ttitle\tpages\trating\turl\n'
  jq -r '.lines[]' <<< "$result"
} | column -t -s $'\t' -R 1,5

if [[ -n "$limit" && "$total" -gt "$limit" ]]; then
  echo
  echo "Showing $limit of $total cached book(s) — omit --limit to see the rest."
fi
