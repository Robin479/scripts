# Placeholder covers are byte-identical across products/series (confirmed
# directly: Perry Rhodan Erstauflage 3400 and Perry Rhodan Neo 394 share
# the exact same file), so a handful of known hashes catch a placeholder
# on the very first product it's ever seen on, before any collision has
# had a chance to accumulate. Extend via the known_placeholder_hashes
# config key (comma-separated, merged with this list) rather than editing
# this file, if the shop ever introduces another variant. Both hashes
# below are confirmed real, live examples (see CLAUDE.md):
#   - the full-resolution image (what bs::download_cover actually saves)
#   - the _600x600 thumbnail variant (kept too, in case a future change
#     starts saving that resolution instead)
readonly BS_KNOWN_PLACEHOLDER_HASHES=(
  0a504b002eb1359f1b178c25fcd32818fec2d7a47adf1d8dbb885f965ca2ba7f
  4eaafbe8709bc38712d0956fdb96dd26cf47339367beb52e4b910bb27cc2d007
)

bs::products_dir() {
  local dir; dir="$(bs::data_dir)/products"
  mkdir -p "$dir"
  echo "$dir"
}

bs::product_file() {
  echo "$(bs::products_dir)/$1.json"
}

bs::images_dir() {
  local dir; dir="$(bs::data_dir)/images"
  mkdir -p "$dir"
  echo "$dir"
}

# Prints the path of product $1's cached image, whatever its extension --
# empty if none is cached yet.
bs::image_file() {
  local id="$1" dir; dir="$(bs::images_dir)"
  local f
  for f in "$dir/$id".*; do
    [[ -e "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

bs::image_hashes_file() {
  local file; file="$(bs::data_dir)/image_hashes.json"
  [[ -f "$file" ]] || echo '{}' > "$file"
  echo "$file"
}

bs::is_known_placeholder_hash() {
  local hash="$1" h
  for h in "${BS_KNOWN_PLACEHOLDER_HASHES[@]}"; do
    [[ "$h" == "$hash" ]] && return 0
  done
  local extra; extra="$(bs::config_get known_placeholder_hashes "")"
  IFS=',' read -r -a extra_arr <<< "$extra"
  for h in "${extra_arr[@]}"; do
    [[ -n "$h" && "$h" == "$hash" ]] && return 0
  done
  return 1
}

# Registers $2 (a product id) under $1 (its cover's sha256) in
# image_hashes.json, then recomputes cover_status for every product
# sharing that hash -- placeholder if it's a known hash or shared by 2+
# products, final otherwise. Retroactively flips an earlier "final"
# product back to "placeholder" the moment a second one collides with it.
bs::register_image_hash() {
  local hash="$1" product_id="$2"
  local hashes_file; hashes_file="$(bs::image_hashes_file)"

  local tmp; tmp="$(mktemp)"
  jq --arg hash "$hash" --arg id "$product_id" \
    '.[$hash] = ((.[$hash] // []) + [$id] | unique)' \
    "$hashes_file" > "$tmp" && mv "$tmp" "$hashes_file"

  local status="final"
  local count; count="$(jq --arg hash "$hash" '(.[$hash] // []) | length' "$hashes_file")"
  if bs::is_known_placeholder_hash "$hash" || (( count >= 2 )); then
    status="placeholder"
  fi

  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    local pfile; pfile="$(bs::product_file "$pid")"
    [[ -f "$pfile" ]] || continue
    local ptmp; ptmp="$(mktemp)"
    jq --arg status "$status" '.cover_status = $status' "$pfile" > "$ptmp" && mv "$ptmp" "$pfile"
  done < <(jq -r --arg hash "$hash" '(.[$hash] // [])[]' "$hashes_file")
}

# Extracts total page count from a fetched category listing page.
bs::listing_page_count() {
  local html_file="$1"
  local n; n="$(xidel -s "$html_file" --extract-kind=xquery3 -e 'string((//div[@data-pages])[1]/@data-pages)' 2> /dev/null)"
  echo "${n:-1}"
}

# Extracts every product on a fetched listing page, newest/highest issue
# first (the site's own default order), one JSON object per line:
# {product_id, title, url}.
bs::listing_products() {
  local html_file="$1"
  # shellcheck disable=SC2016 # single-quoted on purpose -- this is an xidel xquery program, its own $-variables aren't bash's
  xidel -s "$html_file" --extract-kind=xquery3 -e '
    [for $box in //div[contains(@class,"product--box")]
     return {
       "ordernumber": string($box/@data-ordernumber),
       "title": normalize-space(string(($box//a[@class="product--title"])[1]/@title)),
       "url": string(($box//a[@class="product--title"])[1]/@href)
     }]
  ' --output-format=json-wrapped 2> /dev/null \
    | jq -c '.[0][] | select(.ordernumber != "") | {product_id: (.ordernumber | ltrimstr("SW")), title, url}'
}

# Fetches a product's detail page and extracts {title, image_url} -- the
# real, full-resolution cover (og:image), not the lazy-load placeholder or
# a small listing thumbnail.
bs::fetch_product_detail() {
  local url="$1" html_file
  html_file="$(mktemp)"
  trap 'rm -f "$html_file"; trap - RETURN' RETURN

  bs::http_get "$url" > "$html_file" || return 1

  xidel -s "$html_file" --extract-kind=xquery3 -e '
    {
      "title": normalize-space(string((//meta[@property="og:title"])[1]/@content)),
      "image_url": string((//meta[@property="og:image"])[1]/@content)
    }
  ' --output-format=json-wrapped 2> /dev/null | jq -c '.[0]'
}

# Extracts the item number for $2 (a title) against series $1's own
# item_pattern -- prints nothing (not an error, just unclassified) if it
# doesn't match, or if it matches something non-numeric. The latter is a
# real, easy-to-hit misconfiguration: `grep -o` always prints the *whole*
# match, not a parenthesized capture group, so a pattern like
# '^Perry Rhodan ([0-9]+):.*' "extracts" the entire title, not just the
# number inside the parentheses -- confirmed directly (see
# project_beam_shop_planned memory / this exact bug report) crashing
# bs::fetch_one_product's `tonumber` and truncating that product's json to
# empty. $3 (quiet) clears the status line before the warning this prints
# to stderr in that case, so it can't garble together with it.
bs::classify_item_number() {
  local series_id="$1" title="$2" quiet="$3" pattern match
  pattern="$(bs::series_item_pattern "$series_id")"
  match="$(grep -oP "$pattern" <<< "$title" | head -1)"
  [[ -z "$match" ]] && return 0

  if [[ ! "$match" =~ ^[0-9]+$ ]]; then
    bs::status_line_clear "$quiet"
    echo "warning: series $series_id's item_pattern matched non-numeric text for \"$title\" -- leaving it unclassified. A capture group like '([0-9]+)' still makes grep print the *whole* match, not just the group -- use a lookbehind instead, e.g. '(?<=Perry Rhodan )[0-9]+' (see 'series edit --item-pattern')" >&2
    return 0
  fi

  echo "$match"
}

# Finishes the job any new cover needs, once it's already sitting at
# images/<id>.<ext> by whatever means (a live download, or a manual
# bs::import_cover) and its metadata is known: hash-based placeholder
# classification (bs::register_image_hash), series/item-number
# classification (bs::classify_item_number), and an atomic
# products/<id>.json write. $6 (quiet) clears the status line before an
# error, same as everywhere else. Prints the resulting cover_status
# ("final"/"placeholder") to stdout on success; nothing on failure
# (reported to stderr).
bs::finalize_product() {
  local product_id="$1" category_id="$2" title="$3" source_url="$4" series_id="$5" quiet="$6"

  local image_file; image_file="$(bs::image_file "$product_id")" || {
    bs::status_line_clear "$quiet"
    echo "error: no image file on disk for product $product_id" >&2
    return 1
  }

  local hash; hash="$(sha256sum "$image_file" | cut -d' ' -f1)"
  bs::register_image_hash "$hash" "$product_id"

  # A category mapping to a series is necessary but not sufficient for a
  # product to actually belong to it -- not every product in a mapped
  # category is a numbered series item (confirmed directly: a book about
  # ship modeling turned up in a Perry Rhodan cycle category). The
  # item_pattern match is the real, final say: no match means no
  # classification at all, series_id included, not just item_number --
  # otherwise a non-series product ends up stamped series_id: "<id>" with
  # item_number: null, which is wrong (it isn't "part of the series with
  # an unknown number", it just isn't part of the series) and skews
  # anything that counts "final products with this series_id" without
  # also requiring item_number != null (confirmed directly: series list's
  # item count).
  local item_number=""
  if [[ -n "$series_id" ]]; then
    item_number="$(bs::classify_item_number "$series_id" "$title" "$quiet")"
    [[ -z "$item_number" ]] && series_id=""
  fi

  # Written to a temp file and moved into place atomically -- a jq
  # failure here (a bad --item-pattern is no longer one, per
  # bs::classify_item_number's own guard above, but this is cheap
  # insurance against any other future one) must never truncate the real
  # product_file to empty, which is exactly what a direct `jq ... >
  # product_file` did before this fix, corrupting an already-successfully-
  # downloaded cover's record.
  local product_file; product_file="$(bs::product_file "$product_id")"
  local tmp; tmp="$(mktemp)"
  if ! jq -n --arg product_id "$product_id" --arg category_id "$category_id" \
    --arg title "$title" --arg source_url "$source_url" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hash "$hash" \
    --arg series_id "$series_id" --arg item_number "$item_number" \
    '{
      product_id: $product_id,
      category_id: $category_id,
      title: $title,
      source_url: (if $source_url == "" then null else $source_url end),
      image_sha256: $hash,
      fetched_at: $fetched_at,
      series_id: (if $series_id == "" then null else $series_id end),
      item_number: (if $item_number == "" then null else ($item_number | tonumber) end),
      cover_status: "final"
    }' > "$tmp"; then
    rm -f "$tmp"
    bs::status_line_clear "$quiet"
    echo "error: could not build product record for $product_id" >&2
    return 1
  fi
  mv "$tmp" "$product_file"

  # bs::register_image_hash already wrote the real cover_status onto disk
  # (it may have flipped this or an earlier colliding product to
  # "placeholder") -- read it back rather than assuming "final" above.
  jq -r '.cover_status' "$product_file"
}

# Records that a fetch attempt for product $1 failed -- writes a minimal
# products/<id>.json (whatever of title/category_id/source_url is known,
# series/item-number classification attempted too, cover_status:
# "failed", failure_reason: $6) instead of leaving no trace at all. This
# matters: without it, a failed attempt is indistinguishable from an item
# that was simply never reached yet, so bs::series_audit could only ever
# report it as "missing" -- confirmed directly against real data (issues
# whose cover download 404s were reported "missing" even though the
# product itself is real and was actually examined) -- and 'covers import
# --series/--item' would have no record to resolve the product id/
# category/title from later either. Never downgrades an existing
# "final"/"placeholder" record (a defensive no-op guard -- shouldn't be
# reachable in practice, since bs::fetch_category only ever attempts a
# product it didn't already consider done).
bs::record_fetch_failure() {
  local product_id="$1" category_id="$2" title="$3" source_url="$4" series_id="$5" reason="$6"

  local product_file; product_file="$(bs::product_file "$product_id")"
  if [[ -f "$product_file" ]]; then
    local status; status="$(jq -r '.cover_status' "$product_file" 2> /dev/null)"
    [[ "$status" == "final" || "$status" == "placeholder" ]] && return 0
  fi

  # Same "item_pattern has the final say" rule as bs::finalize_product --
  # no match means series_id is dropped too, not just item_number.
  local item_number=""
  if [[ -n "$series_id" && -n "$title" ]]; then
    item_number="$(bs::classify_item_number "$series_id" "$title" 1)"
    [[ -z "$item_number" ]] && series_id=""
  fi

  local tmp; tmp="$(mktemp)"
  jq -n --arg product_id "$product_id" --arg category_id "$category_id" \
    --arg title "$title" --arg source_url "$source_url" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg series_id "$series_id" \
    --arg item_number "$item_number" --arg reason "$reason" \
    '{
      product_id: $product_id,
      category_id: $category_id,
      title: (if $title == "" then null else $title end),
      source_url: (if $source_url == "" then null else $source_url end),
      image_sha256: null,
      fetched_at: $fetched_at,
      series_id: (if $series_id == "" then null else $series_id end),
      item_number: (if $item_number == "" then null else ($item_number | tonumber) end),
      cover_status: "failed",
      failure_reason: $reason
    }' > "$tmp" && mv "$tmp" "$product_file"
}

# True if any cached product in category $1 is currently recorded
# "failed" -- see bs::fetch_category for why this matters: once a
# category has completed one full sync, its early-exit shortcut assumes
# an already-"final" item proves everything numerically older is also
# already known, which is no longer safe if an *older* item is stuck
# "failed" (retries would never reach it again, since a newer "final"
# item -- examined first, newest-first -- would trigger the early-exit
# before pagination gets that far back). Grep-prefiltered by category id.
bs::category_has_failures() {
  local category_id="$1" products_dir; products_dir="$(bs::products_dir)"
  local pfile
  while IFS= read -r pfile; do
    [[ -n "$pfile" ]] || continue
    jq -e '.cover_status == "failed"' "$pfile" > /dev/null 2>&1 && return 0
  done < <(grep -rlF "\"category_id\": \"$category_id\"" "$products_dir" 2> /dev/null)
  return 1
}

# Fetches one new product (not yet cached) end to end: detail page, cover
# download, then bs::finalize_product for the classification/write. Any
# failure along the way is recorded via bs::record_fetch_failure rather
# than left untraced (see there for why), reported to stderr (after
# clearing $6/quiet's status line first so it can't garble together with
# it), and the function returns 1. Prints "fetched" or "placeholder" to
# stdout on success; nothing on failure.
bs::fetch_one_product() {
  local product_id="$1" category_id="$2" listing_title="$3" listing_url="$4" series_id="$5" quiet="$6"

  local detail="" title="$listing_title" image_url="" reason=""
  if ! detail="$(bs::fetch_product_detail "$listing_url")"; then
    reason="could not fetch product detail page"
  else
    local detail_title; detail_title="$(jq -r '.title // empty' <<< "$detail")"
    [[ -n "$detail_title" ]] && title="$detail_title"
    image_url="$(jq -r '.image_url // empty' <<< "$detail")"
    [[ -n "$image_url" ]] || reason="no cover image url found on the detail page"
  fi

  if [[ -z "$reason" ]]; then
    local ext="${image_url##*.}"
    [[ "$ext" =~ ^[A-Za-z0-9]{2,4}$ ]] || ext="jpg"
    local dest; dest="$(bs::images_dir)/${product_id}.${ext}"
    bs::http_download "$image_url" "$dest" || reason="could not download cover image (its shop url may be broken)"
  fi

  if [[ -n "$reason" ]]; then
    bs::status_line_clear "$quiet"
    echo "error: product $product_id: $reason ($listing_url) -- recorded as failed; see 'covers import --series <id> --item <n>' once you have the real cover" >&2
    bs::record_fetch_failure "$product_id" "$category_id" "$title" "$image_url" "$series_id" "$reason"
    return 1
  fi

  bs::finalize_product "$product_id" "$category_id" "$title" "$image_url" "$series_id" "$quiet"
}

# Manually registers an already-on-disk cover for product $2 -- for when
# the shop's own copy is unreachable (e.g. a 404 on what should be its
# cover image url) but the user already has the real cover some other
# way. Copies $3 (a local file) into images/, removing any other
# extension already cached for this id first (bs::image_file just globs
# <id>.* and takes the first match, so a stale different-format file left
# behind by an earlier fetch/import would otherwise linger and could win
# that glob unpredictably), then runs it through the exact same
# bs::finalize_product path a live fetch does -- same placeholder-hash
# checks, same series/item-number classification, same atomic write -- so
# an imported cover is indistinguishable from a fetched one afterward.
# $1 (category_id) and $4 (title) can't be reliably re-derived without a
# working fetch, so the caller must supply them. Refuses to overwrite an
# already-cached-*final* record unless $5 (force) -- an existing
# "placeholder" record is always fair game, same as a live re-fetch would
# treat it. Prints the resulting cover_status to stdout on success.
bs::import_cover() {
  local category_id="$1" product_id="$2" src_file="$3" title="$4" force="$5" quiet="$6"

  [[ -f "$(bs::category_file "$category_id")" ]] || {
    echo "error: unknown category $category_id -- run 'categories list' first" >&2
    return 1
  }
  [[ -f "$src_file" ]] || {
    echo "error: no such file: $src_file" >&2
    return 1
  }

  # Only refuse when there's a genuinely intact cover to protect -- a
  # "final" record whose image file is actually missing (exactly a
  # bs::series_audit "broken" finding) has nothing real to overwrite, so
  # it proceeds without --force even though cover_status alone says
  # "final".
  local existing_file; existing_file="$(bs::product_file "$product_id")"
  if [[ -f "$existing_file" ]] && [[ "$(jq -r '.cover_status' "$existing_file" 2> /dev/null)" == "final" ]] \
      && bs::image_file "$product_id" > /dev/null 2>&1 && [[ -z "$force" ]]; then
    echo "error: product $product_id already has a real cached final cover -- pass --force to overwrite" >&2
    return 1
  fi

  local ext="${src_file##*.}"
  [[ "$ext" =~ ^[A-Za-z0-9]{2,4}$ ]] || ext="jpg"
  local images_dir; images_dir="$(bs::images_dir)"
  local dest="${images_dir}/${product_id}.${ext}"
  cp -- "$src_file" "$dest"

  local old
  for old in "${images_dir}/${product_id}".*; do
    [[ -e "$old" && "$old" != "$dest" ]] && rm -f "$old"
  done

  local series_id; series_id="$(bs::series_for_category "$category_id")" || series_id=""

  bs::finalize_product "$product_id" "$category_id" "$title" "" "$series_id" "$quiet"
}

# Marker file recording that a fetch run has walked category $1 all the
# way to the true end of its pagination at least once, uninterrupted and
# without --limit cutting it short. Existence, not content or mtime, is
# what matters -- see bs::fetch_category for why this needs to exist at
# all (a bare "is this one product already cached" check isn't safe to
# use as a stop condition until a full pass has actually happened once).
bs::category_synced_marker() {
  echo "$(bs::categories_dir)/.synced-$1"
}

# Paginates category $1 (its own cached url), fetching any product not
# already cached as "final". Stops early once an already-"final" product
# is encountered -- releases are numerically monotonic, newest-first, so
# everything after that point is already known -- unless $2 (force) is
# set, OR unless this category has never had a fetch run walk it all the
# way to the end before (see bs::category_synced_marker), OR unless it
# currently has any "failed" record at all (see
# bs::category_has_failures). That last guard matters for the same root
# reason as the sync-marker one: a "final" item examined first
# (newest-first) would otherwise trigger the early-exit before pagination
# ever reaches an *older*, still-"failed" item stuck behind it, so a
# stuck failure would never get retried again by a routine run once the
# category's first full sync completed -- confirmed directly (a
# 404'd-cover item stayed permanently unreachable to routine re-fetches).
# Both guards matter together: without the sync-marker one, an
# interrupted backfill (killed partway through a large category, having
# already cached the newest N items) could never be resumed correctly --
# the very next run's page 1 is entirely already-cached items, so the
# naive early-exit would trigger immediately, on the very first item, and
# the older, never-fetched tail of the category would silently never get
# checked again (confirmed directly: exactly the failure mode reported
# against this code). Until a category has completed one full,
# uninterrupted pass with no outstanding failures, an already-cached item
# here is skipped (not re-fetched, no need) rather than treated as proof
# there's nothing left further down -- so a run resumes/retries correctly
# no matter where a previous one was cut off or which items it failed on,
# at the cost of still paginating (not re-downloading) through however
# much of the category is already done. $3 is the owning series id (may be
# empty -- classification is then skipped). $4 (limit) caps how many
# *new* covers are downloaded; empty means unlimited -- a limited run
# never marks the category synced, precisely because it was deliberately
# cut short and can't prove it reached the end. $5 (quiet, see
# bs::fetch_quiet) suppresses the self-updating status line shown while
# paginating/fetching -- this can run for a long time on a large initial
# backfill (one throttled request per page, plus one per new product's
# detail page and cover download), so showing what's currently happening
# matters here. Prints a final "<new> new (of which <placeholder>
# placeholder)[, <skipped> already cached (resuming an incomplete
# backfill)]" summary line to stdout.
bs::fetch_category() {
  local category_id="$1" force="$2" series_id="$3" limit="$4" quiet="$5"
  local cat_file; cat_file="$(bs::category_file "$category_id")"
  [[ -f "$cat_file" ]] || { echo "error: unknown category $category_id -- run 'categories list' first" >&2; return 1; }
  local base_url; base_url="$(jq -r '.url' "$cat_file")"

  local synced_marker; synced_marker="$(bs::category_synced_marker "$category_id")"
  local already_synced=""
  if [[ -f "$synced_marker" ]] && ! bs::category_has_failures "$category_id"; then
    already_synced=1
  fi

  local new=0 placeholder=0 skipped=0 stop=0 limited=0 page=1 pages=1 pages_known=""

  while (( page <= pages && stop == 0 )); do
    local page_url="$base_url"
    (( page > 1 )) && page_url="${base_url}?p=${page}"

    bs::status_line "category $category_id: fetching page $page${pages_known:+/$pages}..." "$quiet"
    local html_file; html_file="$(mktemp)"
    bs::http_get "$page_url" > "$html_file" || { rm -f "$html_file"; bs::status_line_clear "$quiet"; return 1; }
    pages="$(bs::listing_page_count "$html_file")"
    pages_known=1

    local row product_id title url pfile
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      product_id="$(jq -r '.product_id' <<< "$row")"
      title="$(jq -r '.title' <<< "$row")"
      url="$(jq -r '.url' <<< "$row")"
      pfile="$(bs::product_file "$product_id")"

      bs::status_line "category $category_id p$page/$pages: examining $product_id..." "$quiet"

      local cached_final=""
      [[ -f "$pfile" ]] && [[ "$(jq -r '.cover_status' "$pfile")" == "final" ]] && cached_final=1

      if [[ -n "$cached_final" && -z "$force" ]]; then
        if [[ -n "$already_synced" ]]; then
          stop=1
          break
        fi
        skipped=$((skipped + 1))
        continue
      fi

      if [[ -n "$limit" && "$new" -ge "$limit" ]]; then
        stop=1
        limited=1
        break
      fi

      bs::status_line "category $category_id p$page/$pages: fetching $product_id ($title)..." "$quiet"
      local outcome
      outcome="$(bs::fetch_one_product "$product_id" "$category_id" "$title" "$url" "$series_id" "$quiet")" || continue
      new=$((new + 1))
      [[ "$outcome" == "placeholder" ]] && placeholder=$((placeholder + 1))
      bs::status_line_clear "$quiet"
      echo "$product_id -> $outcome ($title)"
    done < <(bs::listing_products "$html_file")

    rm -f "$html_file"
    page=$((page + 1))
  done

  # Only mark this category as fully synced once a run has genuinely
  # walked it end to end without --limit cutting it short -- otherwise a
  # future run's early-exit shortcut would wrongly assume there's nothing
  # left beyond wherever this run happened to stop.
  [[ "$limited" -eq 0 ]] && touch "$synced_marker"

  bs::status_line_clear "$quiet"
  local summary="$new new (of which $placeholder placeholder)"
  [[ "$skipped" -gt 0 ]] && summary="$summary, $skipped already cached (resuming an incomplete backfill)"
  echo "$summary"
}
