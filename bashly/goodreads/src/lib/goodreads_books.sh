# Default for the book_cache_ttl config key (seconds).
readonly GR_BOOK_CACHE_TTL_DEFAULT=$((100 * 24 * 3600))

gr::book_dir() {
  echo "$(gr::data_dir)/books"
}

gr::book_file() {
  echo "$(gr::book_dir)/$1.json"
}

# The title slug is decorative; book URLs resolve by id alone.
gr::book_url() {
  echo "https://www.goodreads.com/book/show/$1"
}

# Random grammatical fake slug, e.g. "a-blue-box" or "three-old-lamps".
gr::random_book_slug() {
  local -a number_words=(one two three four five six seven eight nine ten eleven twelve)
  local -a adjectives=(
    red orange yellow green blue purple pink brown black white gray
    big small tiny huge heavy light shiny dull round square smooth rough
    old new bright plain fancy soft hard tall short wide narrow
  )
  local -a nouns_sg=(box chair table lamp bottle book cup stone wheel key jar brush)
  local -a nouns_pl=(boxes chairs tables lamps bottles books cups stones wheels keys jars brushes)

  local first plural
  case $((RANDOM % 3)) in
    0) first="the"; plural=$((RANDOM % 2)) ;;
    1) first="a"; plural=0 ;;
    2)
      first="${number_words[$((RANDOM % ${#number_words[@]}))]}"
      [[ "$first" == one ]] && plural=0 || plural=1
      ;;
  esac

  local adjective="${adjectives[$((RANDOM % ${#adjectives[@]}))]}"
  [[ "$first" == a && "$adjective" =~ ^[aeiou] ]] && first="an"

  local idx=$((RANDOM % ${#nouns_sg[@]}))
  local noun="${nouns_sg[$idx]}"
  [[ "$plural" -eq 1 ]] && noun="${nouns_pl[$idx]}"

  echo "$first-$adjective-$noun"
}

# Fetches book $1 and writes books/<id>.json: our fields (book_id,
# canonical_url) * the page's JSON-LD * fields from __NEXT_DATA__'s
# apolloState (right side wins). Prints the file path on success.
# canonical_url is the work's preferred edition and may be a different id;
# `url` is always this edition's own.
# Every stage is checked explicitly before the final mv, not left to set -e
# (errexit is off when called inside && / || / if, and jq exits 0 on empty
# input), so a failure never blanks a good cache.
gr::refresh_book() {
  local id="$1"
  mkdir -p "$(gr::book_dir)"

  local html ld_json next_data apollo_json tmp_book
  html="$(mktemp)"
  ld_json="$(mktemp)"
  next_data="$(mktemp)"
  apollo_json="$(mktemp)"
  tmp_book="$(mktemp)"
  # One trap for all temp files: traps replace each other, they don't stack.
  trap 'rm -f "$html" "$ld_json" "$next_data" "$apollo_json" "$tmp_book"' EXIT

  # Fake slug so the request looks like normal browser traffic.
  if ! GR_HTTP_EXPECT="$GR_HTTP_EXPECT_CANONICAL" gr::http_get "$(gr::book_url "$id")-$(gr::random_book_slug)" > "$html"; then
    gr::term_clear_line
    echo "error: could not fetch book $id from goodreads.com" >&2
    return 1
  fi

  local canonical_url
  canonical_url="$(xidel -s "$html" -e '(//link[@rel="canonical"])[1]/@href' 2>/dev/null)" || true
  if [[ -z "$canonical_url" ]]; then
    gr::term_clear_line
    echo "error: no canonical link found for book $id — page may not be a valid book page" >&2
    gr::save_bad_response "$html"
    return 1
  fi

  xidel -s "$html" -e '(//script[@id="__NEXT_DATA__"])[1]' > "$next_data" 2>/dev/null
  if [[ ! -s "$next_data" ]]; then
    gr::term_clear_line
    echo "error: no __NEXT_DATA__ found for book $id — page structure may have changed" >&2
    return 1
  fi

  # .query.book_id is the route segment "<id>-<slug>"; compare its id prefix.
  local requested_book_id
  requested_book_id="$(jq -r '.query.book_id // empty' "$next_data")"
  if [[ "${requested_book_id%%-*}" != "$id" ]]; then
    gr::term_clear_line
    echo "error: fetched page is for book '${requested_book_id:-<none>}', not the requested $id — refusing to cache under the wrong id" >&2
    return 1
  fi

  # apolloState strings need their own clean_or_null (whitespace squeeze,
  # "" -> null): they win the final merge over the cleaned JSON-LD.
  jq -c --arg id "$id" '
    def epoch_to_date: if . then (./1000 | gmtime | strftime("%Y-%m-%d")) else null end;
    def epoch_to_year: if . then (./1000 | gmtime | strftime("%Y")) else null end;
    def id_from_url(pat): if . then (try (capture(pat).id) catch null) else null end;
    def squeeze_ws: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    def clean_or_null: if . == null or . == "" then null else squeeze_ws end;
    def drop_nulls: with_entries(select(.value != null));
    def drop_empty: with_entries(select(.value != null and .value != ""));

    .props.pageProps.apolloState as $state
    | ($state | to_entries[] | select(.key | startswith("Book:")) | .value | select((.legacyId | tostring) == $id)) as $book
    | ($state[$book.work.__ref // ""]) as $work
    # $isbn: every distinct, cleaned, non-empty value from details.isbn and
    # details.isbn13 combined and deduped — not "isbn if it looks ISBN-10"
    # alone, since Goodreads sometimes puts the same 13-digit value in both
    # fields (POD editions with no true ISBN-10; confirmed on id
    # 229004405), and `unique` collapses that. isbn10/isbn13 are then just
    # the 10-char / 13-char entry in $isbn, if any.
    | ([$book.details.isbn, $book.details.isbn13] | map(clean_or_null) | map(select(. != null)) | unique | sort_by([-length, .])) as $isbn
    | ($isbn | map(select(length == 10)) | first // null) as $isbn10
    | ($isbn | map(select(length == 13)) | first // null) as $isbn13
    | {
        legacyId: $book.legacyId,
        url: $book.webUrl,
        title: ($book.title | clean_or_null),
        description: ($book["description({\"stripped\":true})"] // null | clean_or_null),
        published: ($book.details.publicationTime | epoch_to_date),
        publisher: ($book.details.publisher // null),
        isbn10: $isbn10,
        isbn13: $isbn13,
        isbn: $isbn,
        asin: ($book.details.asin // null),
        genres: [$book.bookGenres[]? | .genre.webUrl | id_from_url("/genres/(?<id>[^/?]+)")],
        contributors: (
          ([$book.primaryContributorEdge] + ($book.secondaryContributorEdges // []))
          | map(select(. != null))
          | map({role: .role, name: (($state[.node.__ref] // {}).name | clean_or_null), url: ($state[.node.__ref] // {}).webUrl})
        ),
        series: [$book.bookSeries[]? | .userPosition as $position | .series.__ref as $ref | ($state[$ref]) | {name: (.title | clean_or_null), series_id: (.webUrl | id_from_url("/series/(?<id>[0-9]+)")), url: .webUrl, position: $position}],
        work: ({
          legacyId: $work.legacyId,
          url: ($work.details.webUrl // null),
          title: ($work.details.originalTitle // null | clean_or_null),
          published: ($work.details.publicationTime | epoch_to_date),
          awards: [$work.details.awardsWon[]? | {award_id: (.webUrl | id_from_url("/award/show/(?<id>[0-9]+)")), name: (.name | clean_or_null), url: .webUrl, date: (.awardedAt | epoch_to_year), designation, category} | drop_empty]
        } | drop_nulls)
      }
    | drop_nulls
  ' "$next_data" | head -n1 > "$apollo_json"

  if [[ ! -s "$apollo_json" ]]; then
    gr::term_clear_line
    echo "error: could not find book data for book $id in __NEXT_DATA__ — page structure may have changed" >&2
    return 1
  fi

  xidel -s "$html" -e '(//script[@type="application/ld+json"])[1]' 2>/dev/null | jq '
    walk(
      if type == "string" then
        gsub("\\s+"; " ")
        | gsub("&lt;"; "<")
        | gsub("&gt;"; ">")
        | gsub("&quot;"; "\"")
        | gsub("&#39;"; "'"'"'")
        | gsub("&apos;"; "'"'"'")
        | gsub("&amp;"; "&")
      else . end
    )' > "$ld_json"

  if [[ ! -s "$ld_json" ]]; then
    gr::term_clear_line
    echo "error: no book JSON-LD found for book $id — page may not be a valid book page" >&2
    return 1
  fi

  if ! jq -S -n \
      --arg id "$id" \
      --arg canonical_url "$canonical_url" \
      --slurpfile apollo "$apollo_json" \
      --slurpfile ld "$ld_json" \
      '{book_id: $id, canonical_url: $canonical_url} * $ld[0] * $apollo[0]' \
      > "$tmp_book" || [[ ! -s "$tmp_book" ]]; then
    gr::term_clear_line
    echo "error: could not build JSON for book $id" >&2
    return 1
  fi

  mv "$tmp_book" "$(gr::book_file "$id")"
  gr::book_file "$id"
}

# True if book $1 is cached and younger than book_cache_ttl seconds.
gr::book_fresh() {
  local id="$1" book_file ttl threshold fresh
  book_file="$(gr::book_file "$id")"
  [[ -f "$book_file" ]] || return 1

  ttl="$(gr::config_get book_cache_ttl "$GR_BOOK_CACHE_TTL_DEFAULT")"
  threshold="$(date -d "-${ttl} seconds" +'%Y-%m-%d %H:%M:%S')"
  fresh="$(find "$book_file" -newermt "$threshold" 2>/dev/null)" || true
  [[ -n "$fresh" ]]
}

# Prints book $1 as one-line JSON, refreshing the cache if stale or with
# --force ($2). A failed refresh fails, never falls back to stale data.
gr::book_json() {
  local id="$1"
  local force="${2:-}"
  local book_file
  book_file="$(gr::book_file "$id")"
  mkdir -p "$(gr::book_dir)"

  if ! gr::book_fresh "$id" || [[ "$force" == "--force" ]]; then
    gr::refresh_book "$id" > /dev/null || return 1
  fi

  if [[ ! -f "$book_file" ]]; then
    echo "error: no cached data for book $id" >&2
    return 1
  fi

  jq -c . "$book_file"
}
