# Safety cap for gr::discover_blog_ids's pagination loop — see there.
readonly GR_NEWS_DISCOVER_MAX_PAGES=50

# Minimum book count for gr::refresh_blog's challenge_potential check.
readonly GR_CHALLENGE_LISTING_MIN_BOOKS=40

# Boundary above which challenge_potential alone (no manual override) counts
# as a challenge listing. Moot today — challenge_potential is only ever 0 or
# 1 — but named for when it becomes a real fractional score.
readonly GR_CHALLENGE_POTENTIAL_THRESHOLD=0.5

# Single source of truth for "is this post effectively a challenge listing"
# (gr_challenge_status: manual .challenge override if present, else
# challenge_potential past the threshold) and the display marker
# (gr_challenge_marker: °/*/?/space). Commands that need either prepend this
# constant to their own jq program (`"$GR_CHALLENGE_JQ_DEFS"'...'` — two
# adjacent bash tokens, concatenated into one jq argument) instead of
# duplicating the logic.
# shellcheck disable=SC2034 # used cross-file by blogs_list_command.sh/blogs_get_command.sh's jq programs
readonly GR_CHALLENGE_JQ_DEFS="def gr_challenge_status: if .challenge != null then .challenge else (.challenge_potential >= ${GR_CHALLENGE_POTENTIAL_THRESHOLD}) end; def gr_challenge_marker: if .challenge == false then \"°\" elif .challenge == true then \"*\" elif gr_challenge_status then \"?\" else \" \" end;"

# xidel >=0.9.9 disabled the JSONiq bare-object-literal syntax ({"a": 1}) by
# default under --extract-kind=xquery3, requiring an explicit
# --json-mode=jsoniq to allow it — confirmed directly: gr::refresh_blog's
# book_sections XQuery below (which relies on that syntax) silently got back
# an "_error" JSON blob instead of real data on 0.9.9 without the flag, which
# then broke jq --argjson downstream. xidel 0.9.8 has no --json-mode option
# at all (errors "Unknown option" — but exits 0 and prints its usage text to
# stdout, so this would silently reappear as the same downstream jq failure,
# just for a different root cause) and doesn't need one — the same bare-object
# syntax already works there with no flag. Detected once here via `xidel
# --help` rather than a hardcoded version check, so this keeps working across
# whichever xidel version is actually installed.
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

# The id of the newest post seen on page 1 as of gr::discover_blog_ids's last
# successful run — its short-circuit criterion for later scans. Small
# plain-text state file in the data dir root, same convention as
# gr::throttle's .last_request_at. Only gr::discover_blog_ids ever writes it.
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
# scan) or "--full" (genuine complete walk, what --all needs).
# content_type=articles excludes /interviews/show/ pages (a separate,
# unscraped content type).
#
# Terminates when either: (1) the discovery marker turns up on a page — only
# ids before it in document order are new (--full skips this check
# entirely), or (2) a page contributes no new ids at all (the fallback for
# --full, a marker-less first run, or a since-deleted marker post).
# GR_NEWS_DISCOVER_MAX_PAGES is a safety net above the real page count
# (~17-18).
#
# A short-circuited result is NOT guaranteed complete, and does NOT filter
# out already-cached ids (a marker-less run returns the whole listing) —
# diffing against the real cache is the caller's job (see
# blogs_update_command.sh). The marker itself is only updated once this
# function is about to return successfully, so a failed run leaves it
# untouched.
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
    # own cover image) rather than any /blog/show/ link on the page — a
    # page-wide match also picks up an unrelated promo banner link that
    # sits before the real listing, which broke newest-id detection.
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

# Fetches and caches one blog post. Two successful outcomes: the post still
# exists (fields extracted, cache written), or it's permanently gone (a real
# 404 — recorded via gr::mark_blog_removed, distinct from a transient
# failure via gr::http_status). TTL/force-refresh is gr::blog_json's concern,
# not this function's — it always fetches unconditionally.
gr::refresh_blog() {
  local id="$1"
  mkdir -p "$(gr::blog_dir)"

  # .challenge is a manual override (see `blogs challenge`) that this
  # function never sets, only preserves — read before the cache file gets
  # rebuilt from scratch below. "null" (not unset) when there's nothing to
  # preserve; with_entries(select(.value != null)) drops it at the end.
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
    echo "error: could not fetch blog post $id from goodreads.com (status ${status:-unknown})" >&2
    return 1
  fi

  local canonical_url
  canonical_url="$(xidel -s "$html" -e '(//link[@rel="canonical"])[1]/@href' 2>/dev/null)" || true
  if [[ -z "$canonical_url" ]]; then
    echo "error: no canonical link found for blog post $id — page may not be a valid blog post page" >&2
    return 1
  fi

  # Sanity check, same spirit as gr::refresh_book's __NEXT_DATA__ check.
  local canonical_id
  canonical_id="$(sed -E 's#.*/blog/show/([0-9]+).*#\1#' <<< "$canonical_url")"
  if [[ "$canonical_id" != "$id" ]]; then
    echo "error: fetched page's canonical link is for blog post '$canonical_id', not the requested $id — refusing to cache under the wrong id" >&2
    return 1
  fi

  local title author_and_date like_text
  title="$(xidel -s "$html" -e '(//h1[@class="gr-h1 gr-h1--serif"])[1]' 2>/dev/null)"
  author_and_date="$(xidel -s "$html" -e '(//span[contains(@class,"secondaryTextBottomPadding")])[1]' 2>/dev/null)"
  like_text="$(xidel -s "$html" -e '(//a[contains(@href,"/rating/voters/")])[1]' 2>/dev/null)"
  # Body HTML: internal-only, never persisted — used only for the validity
  # check below and the challenge_potential grid-widget grep (needs real
  # HTML, not text extraction). Written to a file, not a variable — can run
  # well past 500KB.
  xidel -s "$html" -e '(//div[@class="newsShowColumn"])[1]' --output-format=html 2>/dev/null > "$body_html_file"

  if [[ -z "$title" || ! -s "$body_html_file" ]]; then
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

  # Every book in the post, grouped into its own <h1 style="text-align:
  # center"> sections when it has any (most posts get one null-section
  # group). Title comes from the cover-grid <img alt> specifically
  # (contains(@class,"AcrossImage")) — not just the first <img>, since a
  # book's cover is preceded by an often-empty amazonBadge sibling that can
  # itself contain an <img> (caused real "Kindle Unlimited"-titled books
  # once that badge was present). A book mentioned only inline (no cover,
  # no title) is dropped entirely — only cover-having books are wanted.
  # xquery3 is needed for `let` and for `preceding::` (document-order
  # nearest heading, since section headings and books aren't in an
  # ancestor/descendant relationship).
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

  # challenge_potential: 1 if the post uses Goodreads' cover-grid embed
  # (fourAcrossImage/threeAcrossImage, at least one *exact*-class cover —
  # excludes all-audiobook posts, which use the --audiobook modifier) and
  # has at least GR_CHALLENGE_LISTING_MIN_BOOKS books total; else 0. Not
  # proof of any real challenge tie-in — just a "book-listing-shaped
  # candidate" flag for human review (see CLAUDE.md for how these two
  # conditions were arrived at). Plain 0/1 for now, per explicit direction;
  # room for a real fractional score later.
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
    echo "error: could not build JSON for blog post $id" >&2
    return 1
  fi

  mv "$tmp_blog" "$(gr::blog_file "$id")"
  gr::blog_file "$id"
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
