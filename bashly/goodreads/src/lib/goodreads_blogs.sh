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

# content_type=all, not =articles: the articles view isn't date-ordered (an
# older post can sit above newer ones), which broke the discovery marker.
gr::news_url() {
  local page="$1"
  if [[ "$page" -le 1 ]]; then
    echo "https://www.goodreads.com/news?content_type=all"
  else
    echo "https://www.goodreads.com/news?content_type=all&page=$page"
  fi
}

# Holds the newest card date (YYYY-MM-DD) seen by the last successful discovery.
gr::blogs_discovery_marker_file() {
  echo "$(gr::data_dir)/.blogs_discovery_marker"
}

# Prints the marker date; anything else (e.g. a pre-date-marker blog id) prints nothing.
gr::blogs_discovery_marker_get() {
  local file
  file="$(gr::blogs_discovery_marker_file)"
  if [[ -f "$file" ]]; then
    grep -xE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$file" || true
  fi
}

gr::blogs_discovery_marker_set() {
  echo "$1" > "$(gr::blogs_discovery_marker_file)"
}

# Converts a listing card timestamp ("7h", "45m", "2d", "Oct 27", "Oct 27,
# 2025") to YYYY-MM-DD; prints nothing for an unknown format. A yearless
# date is this year's, or last year's if that would be in the future.
gr::news_card_date() {
  local text="$1"
  local today
  today="$(date +%F)"

  if [[ "$text" =~ ^([0-9]+)([smhd])$ ]]; then
    local unit
    case "${BASH_REMATCH[2]}" in
      s) unit=seconds ;;
      m) unit=minutes ;;
      h) unit=hours ;;
      d) unit=days ;;
    esac
    date -d "${BASH_REMATCH[1]} $unit ago" +%F
  elif [[ "$text" =~ ^[A-Z][a-z]{2}\ [0-9]{1,2},\ [0-9]{4}$ ]]; then
    date -d "${text/,/}" +%F 2>/dev/null || true
  elif [[ "$text" =~ ^[A-Z][a-z]{2}\ [0-9]{1,2}$ ]]; then
    local year result
    year="$(date +%Y)"
    result="$(date -d "$text $year" +%F 2>/dev/null)" || return 0
    if [[ "$result" > "$today" ]]; then
      result="$(date -d "$text $((year - 1))" +%F 2>/dev/null)" || return 0
    fi
    echo "$result"
  fi
}

# Prints blog post ids from the /news listing, one per line (not filtered
# against the cache). The listing is date-ordered, but same-date posts are
# in no stable order, so the marker is a date, not an id: it stops after the
# first page whose last card is older than the marker date minus one day
# (slack for relative "7h" timestamps being converted in local time), and
# only returns ids dated on or after that cutoff (or undatable). With $1 ==
# "--full", or without a valid marker, it stops only when a page adds no new
# cards. Updates the marker only on success.
gr::discover_blog_ids() {
  local full="${1:-}"
  local marker="" cutoff=""
  if [[ "$full" != "--full" ]]; then
    marker="$(gr::blogs_discovery_marker_get)"
  fi
  if [[ -n "$marker" ]]; then
    cutoff="$(date -d "$marker - 1 day" +%F)"
  fi

  local page=1
  local all_ids="" all_hrefs=""
  local newest_date=""
  # Per-page temp file, removed directly (a RETURN trap would only catch the last).
  local html

  while (( page <= GR_NEWS_DISCOVER_MAX_PAGES )); do
    html="$(mktemp)"

    if ! gr::http_get "$(gr::news_url "$page")" > "$html"; then
      echo "error: could not fetch news listing page $page" >&2
      rm -f "$html"
      return 1
    fi

    # "<href>|<timestamp>" per listing card. The timestamp only exists on
    # real cards (not the header's promo /blog/show/ link); interview cards
    # (/interviews/show/) count for dates but contribute no id.
    local cards
    cards="$(xidel -s "$html" -e '//small[@class="editorialCard__timestamp"]/a/concat(@href, "|", normalize-space(.))' 2>/dev/null)" || true
    rm -f "$html"

    local line href stamp card_date id page_ids="" page_hrefs="" last_date=""
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      href="${line%%|*}"
      page_hrefs="${page_hrefs}${page_hrefs:+$'\n'}${href}"
      stamp="${line#*|}"
      card_date="$(gr::news_card_date "$stamp")"
      last_date="$card_date"
      if [[ -n "$card_date" && "$card_date" > "$newest_date" ]]; then
        newest_date="$card_date"
      fi
      if [[ -n "$cutoff" && -n "$card_date" && "$card_date" < "$cutoff" ]]; then
        continue
      fi
      if [[ "$href" =~ /blog/show/([0-9]+) ]]; then
        id="${BASH_REMATCH[1]}"
        page_ids="${page_ids}${page_ids:+$'\n'}${id}"
      fi
    done <<< "$cards"

    # Every card's href, not just blog ids: a page of only interview cards
    # isn't the end of the listing.
    local new_on_page
    new_on_page="$(comm -23 <(sort -u <<< "$page_hrefs" | grep -v '^$') <(sort -u <<< "$all_hrefs"))" || true
    all_hrefs="${all_hrefs}${all_hrefs:+$'\n'}${page_hrefs}"
    all_ids="${all_ids}${all_ids:+$'\n'}${page_ids}"

    # The last card, not the oldest: a stray old card further up the page
    # mustn't end the scan.
    if [[ -n "$cutoff" && -n "$last_date" && "$last_date" < "$cutoff" ]]; then
      break
    fi
    if [[ -z "$new_on_page" ]]; then
      break
    fi

    page=$((page + 1))
  done

  if [[ -n "$newest_date" ]]; then
    gr::blogs_discovery_marker_set "$newest_date"
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
