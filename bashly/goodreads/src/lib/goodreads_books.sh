# Default for the book_cache_ttl config key (seconds), used when unset.
readonly GR_BOOK_CACHE_TTL_DEFAULT=$((100 * 24 * 3600))

gr::book_dir() {
  echo "$(gr::data_dir)/books"
}

gr::book_file() {
  echo "$(gr::book_dir)/$1.json"
}

# Goodreads book URLs resolve by id alone — the trailing title-slug part is
# decorative. Confirmed directly: fetched /book/show/199698485-the-god-of-the-woods
# and /book/show/199698485 and compared them — both HTTP 200, identical
# <title> and identical <link rel="canonical"> (which itself always carries
# the full slug, regardless of which form was requested). So always
# construct book URLs from the id alone here — gr::refresh_book appends its
# own decorative random slug (gr::random_book_slug) right before fetching;
# see there for why that's not done in this function instead.
gr::book_url() {
  echo "https://www.goodreads.com/book/show/$1"
}

# A random three-word "title" — grammatically plausible but meaningless —
# for gr::refresh_book to append to gr::book_url's id-only URL right before
# fetching, purely so the request looks like normal browser traffic
# (".../show/<id>-a-blue-box") rather than a bare numeric id — never meant
# to be accurate, and kept out of gr::book_url itself since not every
# caller of that necessarily wants a fake slug attached. First word is
# either an article ("a"/"an", chosen for whichever of the two fits the
# adjective that follows; or "the") or a spelled-out number
# ("two".."twelve"); second word is a generic adjective (color or similar
# generic, applicable to any object); third word is a noun naming a
# generic object, in the singular or plural form the first word
# grammatically requires (singular after "a"/"an"/"one", plural after any
# other number, either after "the").
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

# Book pages don't need a login, so this fetches account-less: COOKIE_JAR
# already points at the shared gr::generic_cookie_jar by the time this runs
# (src/before.sh's before_hook calls gr::init_cookie_jar once per invocation,
# right after argument parsing — see there for why that's the correct spot
# rather than calling it here or in bashly's initialize() hook), unless a
# caller already set it to something else. gr::http_get itself refuses to
# run at all when --offline was given, so there's no separate offline check
# needed here.
#
# The book JSON is our own scraped fields (book_id, legacyId, url,
# canonical_url) flat-merged with the page's own schema.org/Book JSON-LD
# (<script type="application/ld+json">) — chosen deliberately over nesting
# the JSON-LD under its own key, and @context/@type are kept (not stripped)
# so the result stays real, valid JSON-LD, just extended with our own
# fields. Before merging, every string value in the JSON-LD is squeezed
# (collapse whitespace runs to one space) and HTML-entity-decoded —
# Goodreads' own template leaves both kinds of junk in there (e.g. author
# name "Liz    Moore", awards text containing literal "&amp;" instead of
# "&" even though this is already inside a <script> block, where entities
# shouldn't need decoding at all).
#
# canonical_url (<link rel="canonical">) is the *work's* preferred edition
# — it can point at a *different* book id than the one requested (confirmed:
# fetching id 25098993 got a canonical_url embedding id 1744452 instead).
# url is different: it's this *specific* edition's own self URL
# ("webUrl", from Goodreads' embedded Next.js page data — see below), always
# matching the requested id. Don't conflate the two.
#
# Goodreads' frontend is Next.js: every page embeds <script
# id="__NEXT_DATA__" type="application/json">, whose `.query.book_id` is
# the literal route parameter used to serve the page — an independent,
# reliable way to confirm the fetched page is actually for the requested id
# (not a misdirect/mismatch) before ever caching anything under it. That
# same blob's `.props.pageProps.apolloState` holds a GraphQL-normalized
# cache with one or more "Book:<opaque-ref>" entries (one per book
# referenced anywhere on the page, e.g. "other editions" widgets) — find
# the one whose own `.legacyId` matches the requested id, and pull its
# `.legacyId` (stored as-is, in case it ever diverges from book_id — no
# known case yet, but cheap insurance) and `.webUrl` (stored as `url`) from
# there.
#
# All temp files are pre-created and covered by one trap (not one trap per
# mktemp — traps replace each other, they don't stack) so every stage's
# leftovers get cleaned up regardless of which one fails. Every stage that
# can legitimately fail is checked explicitly and returns 1 before the final
# `mv`, never left to `set -e`: a caller invoking gr::book_json as a
# non-final part of an && / || / if-condition list — entirely plausible —
# suppresses errexit for this whole call, and jq treats an empty file as
# valid empty output (exit 0!), so an implicit-only check would let a failed
# refresh silently blank a previously-good cache in that situation. Never
# holds the fetched JSON in a shell variable — only ever in temp files. On
# success, prints the resulting books/<id>.json path to stdout (not its
# contents) — gr::book_json redirects this away since it doesn't need it,
# but it makes gr::refresh_book self-describing for direct/manual use too.
gr::refresh_book() {
  local id="$1"
  mkdir -p "$(gr::book_dir)"

  local html ld_json next_data apollo_json tmp_book
  html="$(mktemp)"
  ld_json="$(mktemp)"
  next_data="$(mktemp)"
  apollo_json="$(mktemp)"
  tmp_book="$(mktemp)"
  trap 'rm -f "$html" "$ld_json" "$next_data" "$apollo_json" "$tmp_book"' EXIT

  # A fake-but-grammatical slug is appended to the id here (not in
  # gr::book_url itself — see there) purely so the request looks like
  # normal browser traffic; goodreads.com ignores it either way (see
  # gr::book_url). This does mean the fetched page's own `.query.book_id`
  # (below) reflects the full "<id>-<slug>" segment, not just $id.
  if ! gr::http_get "$(gr::book_url "$id")-$(gr::random_book_slug)" > "$html"; then
    echo "error: could not fetch book $id from goodreads.com" >&2
    return 1
  fi

  local canonical_url
  canonical_url="$(xidel -s "$html" -e '(//link[@rel="canonical"])[1]/@href' 2>/dev/null)" || true
  if [[ -z "$canonical_url" ]]; then
    echo "error: no canonical link found for book $id — page may not be a valid book page" >&2
    return 1
  fi

  xidel -s "$html" -e '(//script[@id="__NEXT_DATA__"])[1]' > "$next_data" 2>/dev/null
  if [[ ! -s "$next_data" ]]; then
    echo "error: no __NEXT_DATA__ found for book $id — page structure may have changed" >&2
    return 1
  fi

  # .query.book_id is the *entire* route segment we requested, slug and
  # all (gr::book_url always appends one now, see there) — so only its
  # numeric prefix (up to the first "-") is meaningful here, not an exact
  # match against $id.
  local requested_book_id
  requested_book_id="$(jq -r '.query.book_id // empty' "$next_data")"
  if [[ "${requested_book_id%%-*}" != "$id" ]]; then
    echo "error: fetched page is for book '${requested_book_id:-<none>}', not the requested $id — refusing to cache under the wrong id" >&2
    return 1
  fi

  # clean_or_null is applied to every apolloState-sourced string that ends
  # up in the final output (book/work title, description, contributor and
  # series names) — apolloState's own strings can carry the same
  # whitespace-run junk as the JSON-LD's (e.g. author name "Liz    Moore"),
  # but since the final merge is `$ld[0] * $apollo[0]` (apollo wins on any
  # shared key), cleaning only the JSON-LD side — as the original version
  # of this pipeline did — never actually reached the output for these
  # fields. Also treats "" the same as absent (Goodreads' own
  # work.details.originalTitle is "" rather than missing when there's no
  # distinct original title — confirmed directly against a real fetch) so
  # drop_nulls actually drops it instead of leaving a stray `"title": ""`.
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
    # $isbn is every distinct, cleaned, non-empty value from
    # details.isbn/details.isbn13 combined — deliberately built from both
    # fields together and deduped, not "details.isbn if it looks like an
    # ISBN-10" alone: Goodreads sometimes puts the same 13-digit value in
    # both fields (self-published/POD editions with no true ISBN-10 —
    # confirmed directly on id 229004405), and `unique` collapses that
    # automatically instead of needing an explicit isbn-vs-isbn13 equality
    # check. isbn10/isbn13 are then just "the one 10-char / 13-char entry
    # in $isbn, if any" — an ISBN-10 is always exactly 10 characters and an
    # ISBN-13 always exactly 13, so a value can satisfy at most one of the
    # two regardless of which raw field it came from.
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
    echo "error: could not build JSON for book $id" >&2
    return 1
  fi

  mv "$tmp_book" "$(gr::book_file "$id")"
  gr::book_file "$id"
}

# Emits one-line JSON for the given book id, backed by an on-disk cache at
# books/<id>.json, fresh for `book_cache_ttl` config seconds (see
# GR_BOOK_CACHE_TTL_DEFAULT for the fallback when unset). `find -newermt` on
# the exact expected path handles "missing" and "stale" as a single check: it
# prints the path only if the file exists AND is newer than the threshold,
# so empty output means "needs a refresh" either way — no separate
# existence/age checks needed. A second "--force" argument bypasses the TTL
# check and always refreshes — same force-parameter shape as gr::blog_json,
# used by the `books update` command. Refresh always runs via
# gr::refresh_book when needed — --offline is gr::http_get's problem (see
# there), not this function's; a refresh that fails for any reason, offline
# included, fails gr::book_json outright rather than silently falling back
# to stale/missing data. Never holds the JSON in a shell variable — the file
# is the single source of truth, and jq is what reads and re-emits it (which
# doubles as a "is this valid JSON" check).
gr::book_json() {
  local id="$1"
  local force="${2:-}"
  local book_file
  book_file="$(gr::book_file "$id")"
  mkdir -p "$(gr::book_dir)"

  local ttl
  ttl="$(gr::config_get book_cache_ttl "$GR_BOOK_CACHE_TTL_DEFAULT")"

  local threshold
  threshold="$(date -d "-${ttl} seconds" +'%Y-%m-%d %H:%M:%S')"

  local fresh
  fresh="$(find "$book_file" -newermt "$threshold" 2>/dev/null)" || true

  if [[ -z "$fresh" || "$force" == "--force" ]]; then
    gr::refresh_book "$id" > /dev/null || return 1
  fi

  if [[ ! -f "$book_file" ]]; then
    echo "error: no cached data for book $id" >&2
    return 1
  fi

  jq -c . "$book_file"
}
