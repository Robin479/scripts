: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[blog_id]}"
json="${args[--json]:-}"

if ! gr::blog_json "$id" > /dev/null; then
  exit 1
fi

file="$(gr::blog_file "$id")"

if [[ -n "$json" ]]; then
  # The cache file, not gr::blog_json's own compacted one-line output.
  cat "$file"
  exit 0
fi

# One jq call builds a JSON object so book rows can be column-aligned once,
# globally, in bash below (jq has no column-width equivalent).
# "$GR_CHALLENGE_JQ_DEFS"'...' concatenates into one jq argument — see
# GR_CHALLENGE_JQ_DEFS in lib/goodreads_blogs.sh.
result="$(jq "$GR_CHALLENGE_JQ_DEFS"'
  if .removed_remotely then
    {
      removed: true,
      meta: [
        "Blog post \(.blog_id) — confirmed removed from goodreads.com on \(.removed_remotely_detected_at // "?").",
        "URL: \(.url // "?")"
      ]
    }
  else
    {
      removed: false,
      meta: [
        "\(.title // "(no title)")",
        "\(.url // "")",
        ([.author, .published, ((.like_count // empty) | if . then "\(.) likes" else empty end)]
          | map(select(. != null)) | join(" · ")),
        (gr_challenge_marker + " Challenge potential: \(.challenge_potential // 0)"
          + (if .challenge == true then " (manually marked as a challenge listing)"
             elif .challenge == false then " (manually marked as NOT a challenge listing)"
             else "" end))
      ],
      sections: [(.book_sections // [])[] | {
        header: (if .section then "\(.section) (\(.books | length)):" else "Books (\(.books | length)):" end),
        count: (.books | length)
      }],
      rows: [(.book_sections // [])[].books[] | "\(.book_id)\t\(.title // "(no title)")\thttps://goodreads.com/book/show/\(.book_id)"]
    }
  end
' "$file")"

jq -r '.meta[]' <<< "$result"

if [[ "$(jq -r '.removed' <<< "$result")" == "true" ]]; then
  exit 0
fi

echo

if [[ "$(jq -r '.sections | length' <<< "$result")" -eq 0 ]]; then
  echo "No books found in this post."
  exit 0
fi

# book_id right-aligned; url built without www. (superfluous for book
# urls specifically — not true for blog urls, see CLAUDE.md).
mapfile -t aligned_rows < <(jq -r '.rows[]' <<< "$result" | column -t -s $'\t' -R 1)

idx=0
while IFS=$'\t' read -r header count; do
  echo "$header"
  for ((i = 0; i < count; i++)); do
    echo "  ${aligned_rows[idx]}"
    idx=$((idx + 1))
  done
  echo
done < <(jq -r '.sections[] | "\(.header)\t\(.count)"' <<< "$result")
