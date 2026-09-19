# Safety cap for gr::discover_blog_ids's pagination loop — see there.
readonly GR_NEWS_DISCOVER_MAX_PAGES=50

# Minimum book count for gr::refresh_blog's challenge_potential check.
readonly GR_CHALLENGE_LISTING_MIN_BOOKS=40

# Moot today (challenge_potential is only ever 0 or 1) but named for when it
# becomes a real fractional score.
readonly GR_CHALLENGE_POTENTIAL_THRESHOLD=0.5

# Single source of truth for "is this post effectively a challenge listing"
# and its display marker (°/*/?/space). Prepend to a jq program via
# `"$GR_CHALLENGE_JQ_DEFS"'...'` instead of duplicating the logic.
# shellcheck disable=SC2034 # used cross-file by blogs_list_command.sh/blogs_get_command.sh's jq programs
readonly GR_CHALLENGE_JQ_DEFS="def gr_challenge_status: if .challenge != null then .challenge else (.challenge_potential >= ${GR_CHALLENGE_POTENTIAL_THRESHOLD}) end; def gr_challenge_marker: if .challenge == false then \"°\" elif .challenge == true then \"*\" elif gr_challenge_status then \"?\" else \" \" end;"

# xidel >=0.9.9 disabled JSONiq bare-object literals ({"a": 1}) under
# --extract-kind=xquery3 by default, needing --json-mode=jsoniq to allow them
# (confirmed: without it, gr::refresh_blog's book_sections query below
# silently returns an "_error" blob, breaking jq --argjson downstream). 0.9.8
# has no --json-mode flag (errors "Unknown option" but exits 0, same
# downstream failure for a different reason) and doesn't need one. Detected
# via `xidel --help` rather than a hardcoded version check.
if xidel --help 2>/dev/null | grep -q -- '--json-mode'; then
  readonly GR_XIDEL_JSONIQ_FLAG="--json-mode=jsoniq"
else
  readonly GR_XIDEL_JSONIQ_FLAG=""
fi

gr::blog_dir() {
  echo "$(gr::data_dir)/blogs"
}

gr::blog_file() {
  echo "$(gr::blog_dir)/$1.json"
}

# Id-only urls resolve fine (301 to the slug form); a nonexistent id gets a
# real 404, not book pages' WAF fake-200 — no special-casing needed here.
gr::blog_url() {
  echo "https://www.goodreads.com/blog/show/$1"
}

gr::news_url() {
  local page="$1"
  if [[ "$page" -le 1 ]]; then
    echo "https://www.goodreads.com/news?content_type=articles"
  else
    echo "https://www.goodreads.com/news?content_type=articles&page=$page"
  fi
}

# Newest post id seen on page 1 as of gr::discover_blog_ids's last successful
# run (its short-circuit criterion for later scans). Plain-text state file,
# same convention as gr::throttle's .last_request_at.
gr::blogs_discovery_marker_file() {
  echo "$(gr::data_dir)/.blogs_discovery_marker"
}

gr::blogs_discovery_marker_get() {
  local file
  file="$(gr::blogs_discovery_marker_file)"
  if [[ -f "$file" ]]; then
    cat "$file"
  fi
}

gr::blogs_discovery_marker_set() {
  echo "$1" > "$(gr::blogs_discovery_marker_file)"
}

# Blog post ids currently on the /news listing. $1 is "" (short-circuited
# scan) or "--full" (complete walk, what --all needs).
# content_type=articles excludes /interviews/show/ (a separate content type).
#
# Terminates when either the discovery marker turns up on a page (only ids
# before it in document order are new; --full skips this) or a page
# contributes no new ids at all (the fallback for --full, a marker-less first
# run, or a since-deleted marker post). GR_NEWS_DISCOVER_MAX_PAGES is a
# safety net above the real page count (~17-18).
#
# A short-circuited result isn't guaranteed complete and doesn't filter out
# already-cached ids — diffing against the cache is the caller's job (see
# blogs_update_command.sh). The marker is only updated on success, so a
# failed run leaves it untouched.
gr::discover_blog_ids() {
  local full="${1:-}"
  local marker=""
  if [[ "$full" != "--full" ]]; then
    marker="$(gr::blogs_discovery_marker_get)"
  fi

  local page=1
  local all_ids=""
  local newest_id=""
  # Not a function-level `trap ... RETURN` — that would only clean up the
  # last page's temp file. Cleaned up directly after each page instead.
  local html

  while (( page <= GR_NEWS_DISCOVER_MAX_PAGES )); do
    html="$(mktemp)"

    if ! gr::http_get "$(gr::news_url "$page")" > "$html"; then
      echo "error: could not fetch news listing page $page" >&2
      rm -f "$html"
      return 1
    fi

    # Scoped to editorialCard__image--fullHeight (the real listing card's
    # cover image), not any /blog/show/ link — a page-wide match also picks
    # up an unrelated promo banner link, breaking newest-id detection.
    local raw_ids ordered_ids
    raw_ids="$(grep -E '/blog/show/[0-9]+.*editorialCard__image--fullHeight' "$html" | grep -oE '/blog/show/[0-9]+' | grep -oE '[0-9]+')"
    rm -f "$html"
    ordered_ids="$(awk '!seen[$0]++' <<< "$raw_ids")"

    if [[ "$page" -eq 1 ]]; then
      newest_id="$(head -n1 <<< "$ordered_ids")"
    fi

    if [[ -n "$marker" ]] && grep -qxF "$marker" <<< "$ordered_ids"; then
      all_ids="${all_ids}${all_ids:+$'\n'}$(sed "/^${marker}\$/,\$d" <<< "$ordered_ids")"
      break
    fi

    local page_ids new_on_page
    page_ids="$(sort -n -u <<< "$ordered_ids")"
    new_on_page="$(comm -23 <(echo "$page_ids") <(sort -n -u <<< "$all_ids"))"
    if [[ -z "$new_on_page" ]]; then
      break
    fi

    all_ids="${all_ids}${all_ids:+$'\n'}${ordered_ids}"
    page=$((page + 1))
  done

  if [[ -n "$newest_id" ]]; then
    gr::blogs_discovery_marker_set "$newest_id"
  fi

  # Captured into a variable and echoed rather than ending on a bare
  # `... | grep -v '^$'` — grep exits 1 when there's legitimately nothing to
  # print (e.g. "nothing new"), which callers' `|| exit 1` misread as failure.
  local result
  result="$(sort -n -u <<< "$all_ids" | grep -v '^$')"
  echo "$result"
}

# Records a post as confirmed permanently gone (real 404) without touching
# any previously cached content. removed_remotely_detected_at is set once
# and never re-stamped.
gr::mark_blog_removed() {
  local id="$1"
  local blog_file
  blog_file="$(gr::blog_file "$id")"

  if [[ -f "$blog_file" ]] && jq -e '.removed_remotely == true' "$blog_file" > /dev/null 2>&1; then
    return 0
  fi

  local tmp_blog
  tmp_blog="$(mktemp)"
  # Self-clearing: a RETURN trap is global, not scoped to this call.
  trap 'rm -f "$tmp_blog"; trap - RETURN' RETURN

  local detected_at
  detected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -f "$blog_file" ]]; then
    jq -S --arg detected_at "$detected_at" \
      '. + {removed_remotely: true, removed_remotely_detected_at: $detected_at}' \
      "$blog_file" > "$tmp_blog"
  else
    jq -S -n \
      --arg id "$id" \
      --arg url "$(gr::blog_url "$id")" \
      --arg detected_at "$detected_at" \
      '{blog_id: $id, url: $url, removed_remotely: true, removed_remotely_detected_at: $detected_at}' \
      > "$tmp_blog"
  fi

  mv "$tmp_blog" "$blog_file"
}

# Fetches and caches one blog post. Two successful outcomes: still exists
# (fields extracted, cache written) or permanently gone (real 404, recorded
# via gr::mark_blog_removed). TTL/force-refresh is gr::blog_json's concern —
# this always fetches unconditionally.
gr::refresh_blog() {
  local id="$1"
  mkdir -p "$(gr::blog_dir)"

  # .challenge is a manual override (see `blogs challenge`) that this
  # function only preserves, never sets — read before the cache gets
  # rebuilt below. "null" when there's nothing to preserve;
  # with_entries(select(.value != null)) drops it at the end.
  local existing_challenge="null"
  local existing_blog_file
  existing_blog_file="$(gr::blog_file "$id")"
  if [[ -f "$existing_blog_file" ]]; then
    existing_challenge="$(jq 'if has("challenge") then .challenge else null end' "$existing_blog_file")"
  fi

  local html tmp_blog body_html_file
  html="$(mktemp)"
  tmp_blog="$(mktemp)"
  body_html_file="$(mktemp)"
  # See gr::mark_blog_removed for why the trap clears itself.
  trap 'rm -f "$html" "$tmp_blog" "$body_html_file"; trap - RETURN' RETURN

  if ! gr::http_get "$(gr::blog_url "$id")" > "$html"; then
    local status
    status="$(gr::http_status "$(gr::blog_url "$id")")"
    if [[ "$status" == "404" ]]; then
      gr::mark_blog_removed "$id"
      return 0
    fi
    gr::term_clear_line
    echo "error: could not fetch blog post $id from goodreads.com (status ${status:-unknown})" >&2
    return 1
  fi

  local canonical_url
  canonical_url="$(xidel -s "$html" -e '(//link[@rel="canonical"])[1]/@href' 2>/dev/null)" || true
  if [[ -z "$canonical_url" ]]; then
    gr::term_clear_line
    echo "error: no canonical link found for blog post $id — page may not be a valid blog post page" >&2
    return 1
  fi

  # Sanity check, same spirit as gr::refresh_book's __NEXT_DATA__ check.
  local canonical_id
  canonical_id="$(sed -E 's#.*/blog/show/([0-9]+).*#\1#' <<< "$canonical_url")"
  if [[ "$canonical_id" != "$id" ]]; then
    gr::term_clear_line
    echo "error: fetched page's canonical link is for blog post '$canonical_id', not the requested $id — refusing to cache under the wrong id" >&2
    return 1
  fi

  local title author_and_date like_text
  title="$(xidel -s "$html" -e '(//h1[@class="gr-h1 gr-h1--serif"])[1]' 2>/dev/null)"
  author_and_date="$(xidel -s "$html" -e '(//span[contains(@class,"secondaryTextBottomPadding")])[1]' 2>/dev/null)"
  like_text="$(xidel -s "$html" -e '(//a[contains(@href,"/rating/voters/")])[1]' 2>/dev/null)"
  # Internal only, never persisted — used for the validity check below and
  # the challenge_potential grid-widget grep (needs real HTML, not text).
  # Written to a file, not a variable — can run well past 500KB.
  xidel -s "$html" -e '(//div[@class="newsShowColumn"])[1]' --output-format=html 2>/dev/null > "$body_html_file"

  if [[ -z "$title" || ! -s "$body_html_file" ]]; then
    gr::term_clear_line
    echo "error: could not find blog post content for $id — page structure may have changed" >&2
    return 1
  fi

  # "Posted by <author> on <Month> <Day>, <Year>".
  local squeeze='s/^[[:space:]]+|[[:space:]]+$//g; s/[[:space:]]+/ /g'
  title="$(sed -E "$squeeze" <<< "$title")"
  author_and_date="$(sed -E "$squeeze" <<< "$author_and_date")"
  local author published_raw published
  author="$(sed -E 's/^Posted by (.*) on .*$/\1/' <<< "$author_and_date")"
  published_raw="$(sed -E 's/^Posted by .* on (.*)$/\1/' <<< "$author_and_date")"
  published="$(date -d "$published_raw" +%Y-%m-%d 2>/dev/null)" || true

  local like_count
  like_count="$(grep -oE '^[0-9]+' <<< "$like_text")" || true

  # Every book, grouped into its <h1 style="text-align:center"> section (one
  # null-section group when there isn't any). Title comes from the
  # cover-grid <img alt> (contains(@class,"AcrossImage")), not just the
  # first <img> — a book's cover is preceded by an often-empty amazonBadge
  # sibling that can itself contain an <img>, once causing bogus "Kindle
  # Unlimited"-titled books. Inline-only mentions (no cover) are dropped.
  # xquery3 needed for `let` and `preceding::` (nearest heading in document
  # order — headings and books aren't in an ancestor/descendant relation).
  local book_sections
  # shellcheck disable=SC2016 # $a/$section below are xidel's own XQuery variables, not bash expansions — single quotes are deliberate
  # shellcheck disable=SC2086 # GR_XIDEL_JSONIQ_FLAG is a single flag or empty — word-splitting is exactly what's wanted so an empty value contributes no argument
  book_sections="$(xidel -s "$html" --extract-kind=xquery3 ${GR_XIDEL_JSONIQ_FLAG} -e '
    [for $a in (//div[@class="newsShowColumn"])[1]//a[contains(@href,"/book/show/")]
     let $section := ($a/preceding::h1[contains(@style,"text-align:center")])[last()]
     return {
       "book_id": replace($a/@href, ".*?/book/show/([0-9]+).*", "$1"),
       "title": string($a//img[contains(@class,"AcrossImage")]/@alt),
       "section": string($section)
     }]
  ' --output-format=json-wrapped 2>/dev/null | jq '
    def squeeze_ws: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    def clean_or_null: if . == null or . == "" then null else squeeze_ws end;
    # Strip a trailing series reference like "(Series Name, #1)" — only
    # when it ends in a digit, so a real parenthetical title is left alone.
    def strip_series_ref:
      . as $orig
      | ($orig | gsub("\\s*\\([^()]*[0-9]\\)\\s*$"; "")) as $stripped
      | if ($stripped | length) > 0 then $stripped else $orig end;
    .[0] // []
    | to_entries | map(.value + {idx: .key})
    | map(.title = (.title | clean_or_null | if . then strip_series_ref else . end))
    | map(.section = (.section | clean_or_null))
    | group_by(.book_id)
    | map((map(select(.title != null)) | first) // .[0])
    | map(select(.title != null))
    | sort_by(.idx)
    | reduce .[] as $item ([];
        (. as $acc
         | ($acc | map(.section) | index($item.section)) as $pos
         | if $pos != null
           then $acc | .[$pos].books += [{book_id: $item.book_id, title: $item.title}]
           else $acc + [{section: $item.section, books: [{book_id: $item.book_id, title: $item.title}]}]
           end)
      )
  ')"

  local total_books
  total_books="$(jq '[.[].books | length] | add // 0' <<< "$book_sections")"

  # 1 if the post uses Goodreads' cover-grid embed (fourAcrossImage/
  # threeAcrossImage exact class — excludes all-audiobook posts, which use
  # the --audiobook modifier) and has >= GR_CHALLENGE_LISTING_MIN_BOOKS
  # books; else 0. Not proof of a real challenge tie-in, just a
  # "book-listing-shaped candidate" flag for human review (see CLAUDE.md).
  # Plain 0/1 for now; room for a real fractional score later.
  local challenge_potential
  if [[ "$total_books" -ge "$GR_CHALLENGE_LISTING_MIN_BOOKS" ]] \
    && grep -qE 'class="fourAcrossImage"|class="threeAcrossImage"' "$body_html_file"; then
    challenge_potential=1
  else
    challenge_potential=0
  fi

  jq -S -n \
    --arg id "$id" \
    --arg url "$canonical_url" \
    --arg title "$title" \
    --arg author "$author" \
    --arg published "$published" \
    --argjson like_count "${like_count:-null}" \
    --argjson book_sections "$book_sections" \
    --argjson challenge_potential "$challenge_potential" \
    --argjson challenge "$existing_challenge" \
    '{
      blog_id: $id,
      url: $url,
      title: $title,
      author: $author,
      published: ($published | if . == "" then null else . end),
      like_count: $like_count,
      book_sections: $book_sections,
      challenge_potential: $challenge_potential,
      challenge: $challenge
    } | with_entries(select(.value != null))' > "$tmp_blog"

  if [[ ! -s "$tmp_blog" ]]; then
    gr::term_clear_line
    echo "error: could not build JSON for blog post $id" >&2
    return 1
  fi

  mv "$tmp_blog" "$(gr::blog_file "$id")"
  gr::blog_file "$id"
}

# True (0) if blog post $1 is cached at all -- there's no actual TTL to
# check (see below), so "cached" and "fresh" are simply the same
# question here. Exists purely for symmetry with gr::book_fresh, so
# blogs_fetch_command.sh's "ttl" force policy can ask the same shape of
# question `books fetch --all` does, per explicit direction to keep the
# two commands consistent even though the answer here is always
# trivially "yes, if cached at all".
gr::blog_fresh() {
  [[ -f "$(gr::blog_file "$1")" ]]
}

# Cached blog post JSON, backed by blogs/<id>.json. No TTL — blog content
# never changes once published, so "cached" == "fresh"; --force (2nd arg)
# re-fetches anyway. A removed_remotely stub is served like any other
# cached post — callers check that field themselves.
gr::blog_json() {
  local id="$1"
  local force="${2:-}"
  local blog_file
  blog_file="$(gr::blog_file "$id")"
  mkdir -p "$(gr::blog_dir)"

  if [[ ! -f "$blog_file" || "$force" == "--force" ]]; then
    gr::refresh_blog "$id" > /dev/null || return 1
  fi

  if [[ ! -f "$blog_file" ]]; then
    echo "error: no cached data for blog post $id" >&2
    return 1
  fi

  jq -c . "$blog_file"
}
