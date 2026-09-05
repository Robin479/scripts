: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[book_id]}"
json="${args[--json]:-}"

if ! gr::book_json "$id" > /dev/null; then
  exit 1
fi

file="$(gr::book_file "$id")"

if [[ -n "$json" ]]; then
  # The cache file, not gr::book_json's own compacted one-line output.
  cat "$file"
  exit 0
fi

result="$(jq '
  {
    meta: [
      (.title // .name // "(no title)"),
      ([
         (if (.contributors // []) != [] then "by " + ([.contributors[].name] | join(", ")) else empty end),
         (.published // empty),
         (if (.work.published // null) != null and .work.published != .published then "work first published \(.work.published)" else empty end),
         (if (.numberOfPages // null) != null then "\(.numberOfPages) pages" else empty end),
         (if (.aggregateRating.ratingValue // null) != null then
            "\(.aggregateRating.ratingValue)" + (if (.aggregateRating.ratingCount // null) != null then " (\(.aggregateRating.ratingCount) ratings)" else "" end)
          else empty end)
       ] | map(select(. != null and . != "")) | join(" · ")),
      (if (.genres // []) != [] then "Genres: " + (.genres | join(", ")) else empty end),
      (if (.isbn // []) != [] then "ISBN: " + (.isbn | join(", ")) else empty end),
      # Moved to the last meta line, right before the series table — see
      # CLAUDE.md.
      (if (.url // null) != null then "URL: " + .url else empty end)
    ] | map(select(. != null and . != "")),
    # url is built fresh, id-only (no www., no title slug) — same
    # convention as books list/blogs get use for book urls.
    series: [(.series // [])[] | {
      series_id,
      title: (.name + (if .position then " #\(.position)" else "" end)),
      url: ("https://goodreads.com/series/" + .series_id)
    }]
  }
' "$file")"

jq -r '.meta[]' <<< "$result"

if [[ "$(jq -r '.series | length' <<< "$result")" -gt 0 ]]; then
  echo
  echo "Series:"
  jq -r '.series[] | [.series_id, .title, .url] | @tsv' <<< "$result" \
    | column -t -s $'\t' -R 1 \
    | sed 's/^/  /'
fi

description="$(jq -r '.description // empty' "$file")"
if [[ -n "$description" ]]; then
  echo
  echo "Description: $description"
fi
