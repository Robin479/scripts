# Safety cap for gr::discover_blog_ids's pagination (real count ~18).
readonly GR_NEWS_DISCOVER_MAX_PAGES=50

# Minimum book count for challenge_potential.
readonly GR_CHALLENGE_LISTING_MIN_BOOKS=40

readonly GR_CHALLENGE_POTENTIAL_THRESHOLD=0.5

# jq defs: effective challenge status (manual .challenge wins over
# challenge_potential) and its marker (°/*/?/space). Prepend to jq programs.
# shellcheck disable=SC2034 # used by blogs_list/blogs_get command jq programs
readonly GR_CHALLENGE_JQ_DEFS="def gr_challenge_status: if .challenge != null then .challenge else (.challenge_potential >= ${GR_CHALLENGE_POTENTIAL_THRESHOLD}) end; def gr_challenge_marker: if .challenge == false then \"°\" elif .challenge == true then \"*\" elif gr_challenge_status then \"?\" else \" \" end;"

# xidel >=0.9.9 needs --json-mode=jsoniq for the {...} object literals in
# gr::refresh_blog's xquery3; 0.9.8 lacks (and doesn't need) the flag.
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

# Id-only urls 301 to the slug form; a nonexistent id gets a real 404.
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

# Holds the newest post id seen by the last successful discovery.
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

# Prints blog post ids from the /news listing, one per line (not filtered
# against the cache). Stops at the discovery marker (ids before it are new),
# or with $1 == "--full" only when a page adds no new ids. Updates the
# marker only on success.
gr::discover_blog_ids() {
  local full="${1:-}"
  local marker=""
  if [[ "$full" != "--full" ]]; then
    marker="$(gr::blogs_discovery_marker_get)"
  fi

  local page=1
  local all_ids=""
  local newest_id=""
  # Per-page temp file, removed directly (a RETURN trap would only catch the last).
  local html

  while (( page <= GR_NEWS_DISCOVER_MAX_PAGES )); do
    html="$(mktemp)"

    if ! gr::http_get "$(gr::news_url "$page")" > "$html"; then
      echo "error: could not fetch news listing page $page" >&2
      rm -f "$html"
      return 1
    fi

    # Only real listing cards; the header has an unrelated promo /blog/show/ link.
    # awk: order-preserving dedup (position relative to the marker matters).
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

  # Not a bare trailing grep: it exits 1 on empty output, which isn't a failure.
  local result
  result="$(sort -n -u <<< "$all_ids" | grep -v '^$')"
  echo "$result"
}

# Flags post $1 as removed_remotely (after a 404), keeping cached content or
# writing a stub. The detection timestamp is set only once.
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

# Fetches blog post $1 and rebuilds blogs/<id>.json; a 404 instead marks it
# removed_remotely (also success). Prints the file path on success.
gr::refresh_blog() {
  local id="$1"
  mkdir -p "$(gr::blog_dir)"

  # Carry the manual .challenge override across the rebuild.
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
  # Self-clearing: a RETURN trap is global, not scoped to this call.
  trap 'rm -f "$html" "$tmp_blog" "$body_html_file"; trap - RETURN' RETURN

  if ! GR_HTTP_EXPECT="$GR_HTTP_EXPECT_CANONICAL" gr::http_get "$(gr::blog_url "$id")" > "$html"; then
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
    gr::save_bad_response "$html"
    return 1
  fi

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
  # Body HTML (not persisted) for the challenge_potential class grep; a file,
  # not a variable, since it can exceed 500KB.
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

  # Books grouped by the nearest preceding <h1 style="text-align:center">
  # (null section if none), in post order, deduped by id. Title is the cover's
  # AcrossImage <img alt> (an amazonBadge <img> may come first); books with
  # no cover title are dropped. xquery3 is needed for `let`.
  local book_sections
  # shellcheck disable=SC2016 # $a/$section are XQuery variables
  # shellcheck disable=SC2086 # GR_XIDEL_JSONIQ_FLAG is one flag or empty
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

  # 1 if >= GR_CHALLENGE_LISTING_MIN_BOOKS books and at least one plain
  # (non-"--audiobook") cover-grid image, else 0.
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

# Counterpart of gr::book_fresh; blog posts have no TTL, so cached == fresh.
gr::blog_fresh() {
  [[ -f "$(gr::blog_file "$1")" ]]
}

# Prints blog post $1 as one-line JSON, fetching it if uncached or with
# --force ($2). A removed_remotely stub is returned like any other post.
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
