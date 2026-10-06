readonly BS_CATEGORY_SETTLE_PERIOD_DEFAULT=$((14 * 24 * 3600))
readonly BS_CATEGORY_FULL_SYNC_MAX_INTERVAL_DEFAULT=$((180 * 24 * 3600))
readonly BS_CATEGORY_FULL_SYNC_RAMP_DEFAULT=13700000 # ~365 days / ln(10): ~90% of max interval after a year
readonly BS_CATEGORY_FULL_SYNC_SPREAD_DEFAULT=30 # percent

# Extend via the known_placeholder_hashes config key rather than editing this.
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

# Path of product $1's cached image, whatever its extension -- empty if none cached.
bs::image_file() {
  local id="$1" dir; dir="$(bs::images_dir)"
  local f
  for f in "$dir/$id".*; do
    [[ -e "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# Sets product $1's classification override for series $2 to $3 ({"exclude": true} or {"item": N}).
bs::set_product_override() {
  local product_id="$1" series_id="$2" override_json="$3"
  local file; file="$(bs::product_file "$product_id")"
  [[ -f "$file" ]] || { echo "error: product $product_id is not cached yet -- fetch or import it first" >&2; return 1; }

  local content
  content="$(jq --arg sid "$series_id" --argjson ov "$override_json" \
    '.overrides = ((.overrides // {}) + {($sid): $ov})' \
    "$file")" && bs::write_file "$file" "$content"
}

# Removes product $1's override for series $2. Returns 1 if it had none.
bs::unset_product_override() {
  local product_id="$1" series_id="$2"
  local file; file="$(bs::product_file "$product_id")"
  [[ -f "$file" ]] || { echo "error: product $product_id is not cached" >&2; return 1; }

  if ! jq -e --arg sid "$series_id" '.overrides[$sid] != null' "$file" > /dev/null 2>&1; then
    return 1
  fi

  local content
  content="$(jq --arg sid "$series_id" 'del(.overrides[$sid])' "$file")" && bs::write_file "$file" "$content"
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

# Registers $2 under $1's sha256 in image_hashes.json (dropping it from any
# other hash it was registered under before, i.e. a replaced cover), then
# recomputes cover_status for every product sharing that hash -- placeholder
# if known/shared by 2+, else final. Prints that status, since $2's own record
# may not exist yet for this to write it into.
bs::register_image_hash() {
  local hash="$1" product_id="$2"
  local hashes_file; hashes_file="$(bs::image_hashes_file)"

  local content
  content="$(jq --arg hash "$hash" --arg id "$product_id" \
    'map_values(map(select(. != $id))) | with_entries(select(.value != []))
     | .[$hash] = ((.[$hash] // []) + [$id] | unique)' \
    "$hashes_file")" && bs::write_file "$hashes_file" "$content"

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
    local pcontent
    pcontent="$(jq --arg status "$status" '.cover_status = $status' "$pfile")" && bs::write_file "$pfile" "$pcontent"
  done < <(jq -r --arg hash "$hash" '(.[$hash] // [])[]' "$hashes_file")

  echo "$status"
}

# Total page count from a fetched category listing page.
bs::listing_page_count() {
  local html_file="$1"
  local n; n="$(xidel -s "$html_file" --extract-kind=xquery3 -e 'string((//div[@data-pages])[1]/@data-pages)' 2> /dev/null)"
  echo "${n:-1}"
}

# Every product on a fetched listing page, newest first: one
# {product_id, title, subtitle, url} per line (subtitle "" if none -- the
# shop's own second title line, e.g. a cycle name or an episode title).
bs::listing_products() {
  local html_file="$1"
  # shellcheck disable=SC2016 # xidel xquery, not bash vars
  xidel -s "$html_file" --extract-kind=xquery3 -e '
    [for $box in //div[contains(@class,"product--box")]
     return {
       "ordernumber": string($box/@data-ordernumber),
       "title": normalize-space(string(($box//a[@class="product--title"])[1]/@title)),
       "subtitle": normalize-space(string(($box//a[@class="product--title"])[1]/span[contains(concat(" ", normalize-space(@class), " "), " product--subtitle ")])),
       "url": string(($box//a[@class="product--title"])[1]/@href)
     }]
  ' --output-format=json-wrapped 2> /dev/null \
    | jq -c '.[0][] | select(.ordernumber != "") | {product_id: (.ordernumber | ltrimstr("SW")), title, subtitle, url}'
}

# Fetches a product's detail page, extracts {title, subtitle, image_url}
# (og:image; subtitle "" if none).
bs::fetch_product_detail() {
  local url="$1" html_file
  html_file="$(mktemp)"
  trap 'rm -f "$html_file"; trap - RETURN' RETURN

  bs::http_get "$url" > "$html_file" || return 1

  xidel -s "$html_file" --extract-kind=xquery3 -e '
    {
      "title": normalize-space(string((//meta[@property="og:title"])[1]/@content)),
      "subtitle": normalize-space(string((//header[contains(concat(" ", normalize-space(@class), " "), " product--header ")]/following-sibling::h2[contains(concat(" ", normalize-space(@class), " "), " subtitle ")])[1])),
      "image_url": string((//meta[@property="og:image"])[1]/@content)
    }
  ' --output-format=json-wrapped 2> /dev/null | jq -c '.[0]'
}

# Finishes a new cover already sitting at images/<id>.<ext>: placeholder-hash
# classification, an atomic products/<id>.json write, category link (if $2
# given), series classification. $6 subtitle ("" for none). Prints
# resulting cover_status on success.
bs::finalize_product() {
  local product_id="$1" category_id="$2" title="$3" source_url="$4" quiet="$5" subtitle="$6"

  local image_file; image_file="$(bs::image_file "$product_id")" || {
    bs::status_line_clear "$quiet"
    echo "error: no image file on disk for product $product_id" >&2
    return 1
  }

  local hash; hash="$(sha256sum "$image_file" | cut -d' ' -f1)"
  local status; status="$(bs::register_image_hash "$hash" "$product_id")"

  local product_file; product_file="$(bs::product_file "$product_id")"
  local existing_overrides="{}"
  [[ -f "$product_file" ]] && existing_overrides="$(jq -c '.overrides // {}' "$product_file")"

  local content
  if ! content="$(jq -n --arg product_id "$product_id" \
    --arg title "$title" --arg source_url "$source_url" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hash "$hash" \
    --arg status "$status" --argjson overrides "$existing_overrides" --arg subtitle "$subtitle" \
    '{
      product_id: $product_id,
      title: $title,
      subtitle: (if $subtitle == "" then null else $subtitle end),
      source_url: (if $source_url == "" then null else $source_url end),
      image_sha256: $hash,
      fetched_at: $fetched_at,
      cover_status: $status,
      overrides: $overrides
    }')"; then
    bs::status_line_clear "$quiet"
    echo "error: could not build product record for $product_id" >&2
    return 1
  fi
  bs::write_file "$product_file" "$content"

  [[ -n "$category_id" ]] && bs::link_category_product "$category_id" "$product_id"
  bs::classify_product "$product_id" "$title"

  jq -r '.cover_status' "$product_file"
}

# Records a failed fetch attempt for product $1 as products/<id>.json with
# cover_status "failed"/failure_reason $5, instead of leaving no trace. Still
# links category->product. Never downgrades an existing final/placeholder record.
bs::record_fetch_failure() {
  local product_id="$1" category_id="$2" title="$3" source_url="$4" reason="$5" subtitle="$6"

  local product_file; product_file="$(bs::product_file "$product_id")"
  if [[ -f "$product_file" ]]; then
    local status; status="$(jq -r '.cover_status' "$product_file" 2> /dev/null)"
    [[ "$status" == "final" || "$status" == "placeholder" ]] && return 0
  fi

  local existing_overrides="{}"
  [[ -f "$product_file" ]] && existing_overrides="$(jq -c '.overrides // {}' "$product_file")"

  local content
  content="$(jq -n --arg product_id "$product_id" \
    --arg title "$title" --arg source_url "$source_url" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$reason" \
    --argjson overrides "$existing_overrides" --arg subtitle "$subtitle" \
    '{
      product_id: $product_id,
      title: (if $title == "" then null else $title end),
      subtitle: (if $subtitle == "" then null else $subtitle end),
      source_url: (if $source_url == "" then null else $source_url end),
      image_sha256: null,
      fetched_at: $fetched_at,
      cover_status: "failed",
      failure_reason: $reason,
      overrides: $overrides
    }')" && bs::write_file "$product_file" "$content"

  bs::link_category_product "$category_id" "$product_id"
}

# Fetches one new product end to end: detail page, cover download, then
# bs::finalize_product. A failure is recorded via bs::record_fetch_failure and
# reported to stderr. Prints the resulting cover_status on success.
bs::fetch_one_product() {
  local product_id="$1" category_id="$2" listing_title="$3" listing_url="$4" quiet="$5" listing_subtitle="$6"

  local detail="" title="$listing_title" subtitle="$listing_subtitle" image_url="" reason=""
  if ! detail="$(bs::fetch_product_detail "$listing_url")"; then
    reason="could not fetch product detail page"
  else
    local detail_title; detail_title="$(jq -r '.title // empty' <<< "$detail")"
    [[ -n "$detail_title" ]] && title="$detail_title"
    local detail_subtitle; detail_subtitle="$(jq -r '.subtitle // empty' <<< "$detail")"
    [[ -n "$detail_subtitle" ]] && subtitle="$detail_subtitle"
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
    bs::record_fetch_failure "$product_id" "$category_id" "$title" "$image_url" "$reason" "$subtitle"
    return 1
  fi

  bs::finalize_product "$product_id" "$category_id" "$title" "$image_url" "$quiet" "$subtitle"
}

# Manually registers an already-on-disk cover for product $2, running it
# through the same bs::finalize_product path a live fetch does. $1 (category)
# is optional. Refuses to overwrite an existing final cover unless $5 (force).
bs::import_cover() {
  local category_id="$1" product_id="$2" src_file="$3" title="$4" force="$5" quiet="$6"

  if [[ -n "$category_id" ]]; then
    [[ -f "$(bs::category_file "$category_id")" ]] || {
      echo "error: unknown category $category_id -- run 'categories list' first" >&2
      return 1
    }
  fi
  [[ -f "$src_file" ]] || {
    echo "error: no such file: $src_file" >&2
    return 1
  }

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
  # cat, not cp -- cp preserves the source file's own mode bits verbatim.
  cat -- "$src_file" > "$dest"

  local old
  for old in "${images_dir}/${product_id}".*; do
    [[ -e "$old" && "$old" != "$dest" ]] && rm -f "$old"
  done

  local subtitle=""
  [[ -f "$existing_file" ]] && subtitle="$(jq -r '.subtitle // empty' "$existing_file")"
  bs::finalize_product "$product_id" "$category_id" "$title" "" "$quiet" "$subtitle"
}

# Marker: every product in category $1 is complete (final cover on disk) as of
# its mtime, the last full walk. See CLAUDE.md "Category sync".
bs::category_synced_marker() {
  local dir; dir="$(bs::category_dir "$1")/products"
  mkdir -p "$dir"
  echo "${dir}/.synced"
}

# Prints "<mtime> <pid>" for every cached image (one stat over the images dir).
bs::_image_mtimes() {
  local images_dir; images_dir="$(bs::images_dir)"
  shopt -s nullglob
  local files=("$images_dir"/*)
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || return 0
  stat -c '%Y %n' -- "${files[@]}" | while read -r mtime path; do
    path="${path##*/}"
    echo "$mtime ${path%.*}"
  done
}

# Prints each product linked from category $1 that is incomplete: not
# cover_status "final", or no image on disk. $2: output of bs::_image_mtimes.
bs::category_incomplete_ids() {
  local image_mtimes="$2" dir; dir="$(bs::category_dir "$1")/products"
  shopt -s nullglob
  local files=("$dir"/*.json)
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || return 0
  local -A has_image=()
  local mtime pid status
  while read -r mtime pid; do has_image["$pid"]=1; done <<< "$image_mtimes"
  while IFS=$'\t' read -r pid status; do
    [[ "$status" == "final" && -n "${has_image[$pid]:-}" ]] || echo "$pid"
  done < <(jq -r '[.product_id, .cover_status] | @tsv' "${files[@]}")
}

# Sets every link in category $1 to its image's mtime (see CLAUDE.md
# "Category sync"); links without an image are left alone. Prints the newest
# resulting link mtime, or nothing if the category has no linked image. $2:
# output of bs::_image_mtimes.
bs::sync_category_link_times() {
  local image_mtimes="$2" dir; dir="$(bs::category_dir "$1")/products"
  shopt -s nullglob
  local links=("$dir"/*.json)
  shopt -u nullglob
  (( ${#links[@]} > 0 )) || return 0
  local -A image_mtime=()
  local mtime pid path newest=""
  while read -r mtime pid; do [[ -n "$pid" ]] && image_mtime["$pid"]="$mtime"; done <<< "$image_mtimes"
  local images_dir; images_dir="$(bs::images_dir)"
  while read -r mtime path; do
    pid="${path##*/}"
    pid="${pid%.json}"
    local want="${image_mtime[$pid]:-}"
    [[ -n "$want" ]] || continue
    [[ "$mtime" == "$want" ]] || touch -h -d "@$want" -- "$path"
    [[ -z "$newest" || "$want" -gt "$newest" ]] && newest="$want"
  done < <(stat -c '%Y %n' -- "${links[@]}")
  if [[ -n "$newest" ]]; then
    echo "$newest"
  fi
}

# Epoch at which a synced category's next confirming full walk is due, given
# its newest item's epoch $1 and its last full walk's epoch $2 -- the backoff
# strategy, kept separate so it can change. bs::category_fetch_mode ceils the
# result to the end of the settle period.
# interval = max * (1 - e^(-age/ramp)), age = last walk - newest item: grows
# about linearly for young categories, levels off smoothly towards max.
# The interval is then scaled by a factor between 1/x and x, x = 1 + spread,
# log-uniformly distributed and derived from a hash of $2, so categories
# synced in one batch spread out instead of falling due together, while the
# same last walk always yields the same due date.
bs::category_full_sync_due() {
  local newest="$1" last_sync="$2" max ramp spread hash
  max="$(bs::config_get category_full_sync_max_interval "$BS_CATEGORY_FULL_SYNC_MAX_INTERVAL_DEFAULT")"
  ramp="$(bs::config_get category_full_sync_ramp "$BS_CATEGORY_FULL_SYNC_RAMP_DEFAULT")"
  spread="$(bs::config_get category_full_sync_spread "$BS_CATEGORY_FULL_SYNC_SPREAD_DEFAULT")"
  spread="${spread%\%}"
  hash="$(printf '%s' "$last_sync" | sha256sum)"
  # r: the hash's first 8 hex digits (32 bits) as an integer, 0 <= r < 2^32.
  awk -v n="$newest" -v s="$last_sync" -v max="$max" -v ramp="$ramp" \
    -v spread="$spread" -v r="$((16#${hash:0:8}))" \
    'BEGIN {
      age = s - n
      # 4294967296 = 2^32, one past the largest 32-bit r, so u is a
      # pseudo-random fraction with 0 <= u < 1.
      u = r / 4294967296
      # The factor has to be symmetric in the multiplicative sense: stretching
      # by k as likely as shrinking by 1/k. Uniform between 1/x and x is not:
      # for x = 1.3 that is 0.769..1.3, with 1 off-centre (0.231 below, 0.3
      # above), so 56.5% of factors would exceed 1 (median ~1.035). In log
      # space the bounds are symmetric, ln(1/x) = -ln(x), so pick ln(factor)
      # uniformly from -ln(x)..+ln(x) and convert back:
      #   ln(factor) = (2u - 1) * ln(x)  =>  factor = x^(2u - 1)
      # Median and geometric mean are then exactly 1 (arithmetic mean
      # (x - 1/x) / (2 ln x), ~1.012 for x = 1.3).
      x = 1 + spread / 100
      factor = exp((2 * u - 1) * log(x))
      printf "%d\n", s + max * (1 - exp(-age / ramp)) * factor
    }'
}

# Decides how a default refresh walks category $1 -- see CLAUDE.md "Category
# sync". Prints "<mode>[ <epoch>]": "partial" (incomplete products remain),
# "full", "head" (synced, within the settle period, until <epoch>) or "skip"
# (synced, next full walk due at <epoch>). $2 (force) always means "full".
# Also syncs the category's link times first, which the decision depends on.
bs::category_fetch_mode() {
  local category_id="$1" force="$2"
  local image_mtimes; image_mtimes="$(bs::_image_mtimes)"
  local newest; newest="$(bs::sync_category_link_times "$category_id" "$image_mtimes")"
  [[ -n "$force" ]] && { echo "full"; return 0; }

  if [[ -n "$(bs::category_incomplete_ids "$category_id" "$image_mtimes")" ]]; then
    echo "partial"
    return 0
  fi

  local marker; marker="$(bs::category_synced_marker "$category_id")"
  [[ -f "$marker" ]] || { echo "full"; return 0; }

  local last_sync; last_sync="$(stat -c %Y "$marker")"
  local empty=""
  [[ -n "$newest" ]] || { newest="$last_sync"; empty=1; }
  local settle; settle="$(bs::config_get category_settle_period "$BS_CATEGORY_SETTLE_PERIOD_DEFAULT")"
  local settle_end=$((newest + settle))
  local due; due="$(bs::category_full_sync_due "$newest" "$last_sync")"
  (( due < settle_end )) && due="$settle_end"

  local now; now="$(date +%s)"
  if (( now >= due )); then
    echo "full"
  elif [[ -z "$empty" ]] && (( now < settle_end )); then
    echo "head $settle_end"
  else
    echo "skip $due"
  fi
}

# Walks category $1's listing in mode $2 (from bs::category_fetch_mode),
# downloading every new or incomplete product and linking every listed one:
# - partial: stop once every previously incomplete product was seen again and
#   some product is still incomplete; otherwise carry on as a full walk
# - head: stop at the first product that was already linked and complete
# - full: walk to the end
# Reaching the end of pagination, in any mode, prunes links to products no
# longer listed, and sets .synced if everything seen was complete. Finding
# anything incomplete removes .synced.
# Prints "<new> new (of which <incomplete> incomplete)".
bs::fetch_category() {
  local category_id="$1" mode="$2" quiet="$3"
  local cat_file; cat_file="$(bs::category_file "$category_id")"
  [[ -f "$cat_file" ]] || { echo "error: unknown category $category_id -- run 'categories list' first" >&2; return 1; }
  local base_url; base_url="$(jq -r '.url' "$cat_file")"

  local dir; dir="$(bs::category_dir "$category_id")/products"
  local marker; marker="$(bs::category_synced_marker "$category_id")"
  local products_dir; products_dir="$(bs::products_dir)"

  local -A pending=()
  local pid
  if [[ "$mode" == "partial" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && pending["$pid"]=1
    done < <(bs::category_incomplete_ids "$category_id" "$(bs::_image_mtimes)")
    rm -f "$marker"
  fi

  local new=0 incomplete=0 stop=0 page=1 pages=1 pages_known=""
  local -A seen_products=()

  while (( page <= pages && stop == 0 )); do
    local page_url="$base_url"
    (( page > 1 )) && page_url="${base_url}?p=${page}"

    bs::status_line "category $category_id ($mode): fetching page $page${pages_known:+/$pages}..." "$quiet"
    local html_file; html_file="$(mktemp)"
    bs::http_get "$page_url" > "$html_file" || { rm -f "$html_file"; bs::status_line_clear "$quiet"; return 1; }
    pages="$(bs::listing_page_count "$html_file")"
    pages_known=1

    local row product_id title subtitle url pfile link
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      IFS=$'\x01' read -r product_id title subtitle url <<< "$(jq -r '[.product_id, .title, .subtitle, .url] | join("\u0001")' <<< "$row")"
      pfile="${products_dir}/${product_id}.json"
      link="${dir}/${product_id}.json"
      seen_products["$product_id"]=1
      unset 'pending[$product_id]'

      bs::status_line "category $category_id p$page/$pages: examining $product_id..." "$quiet"

      local was_linked=""
      [[ -L "$link" ]] && was_linked=1

      local complete="" cached_status="" cached_subtitle=""
      if [[ -f "$pfile" ]]; then
        IFS=$'\x01' read -r cached_status cached_subtitle <<< "$(jq -r '[.cover_status, (.subtitle // "")] | join("\u0001")' "$pfile")"
        # Fill in / update a cached product's subtitle from the listing --
        # no detail request needed; it changes what matchers see.
        if [[ -n "$subtitle" && "$subtitle" != "$cached_subtitle" ]]; then
          local pcontent; pcontent="$(jq --arg subtitle "$subtitle" '.subtitle = $subtitle' "$pfile")" \
            && bs::write_file "$pfile" "$pcontent" \
            && bs::classify_product "$product_id" "$(jq -r '.title // empty' "$pfile")"
        fi
        [[ "$cached_status" == "final" ]] && bs::image_file "$product_id" > /dev/null && complete=1
      fi

      if [[ -n "$complete" ]]; then
        [[ -n "$was_linked" ]] || bs::link_category_product "$category_id" "$product_id"
        bs::_sync_link_time "$link" "$product_id"
        if [[ "$mode" == "head" && -n "$was_linked" ]]; then
          stop=1
          break
        fi
      else
        bs::status_line "category $category_id p$page/$pages: fetching $product_id ($title)..." "$quiet"
        local outcome=""
        if outcome="$(bs::fetch_one_product "$product_id" "$category_id" "$title" "$url" "$quiet" "$subtitle")"; then
          new=$((new + 1))
          bs::status_line_clear "$quiet"
          echo "$product_id -> $outcome ($title)"
        fi
        bs::_sync_link_time "$link" "$product_id"
        if [[ "$outcome" != "final" ]]; then
          incomplete=$((incomplete + 1))
          rm -f "$marker"
        fi
      fi

      if [[ "$mode" == "partial" && ${#pending[@]} -eq 0 ]]; then
        if (( incomplete > 0 )); then
          stop=1
          break
        fi
        mode="full"
      fi
    done < <(bs::listing_products "$html_file")

    rm -f "$html_file"
    page=$((page + 1))
  done

  # Reached the end of pagination: every listed product was seen.
  if [[ "$stop" -eq 0 ]]; then
    local l
    shopt -s nullglob
    for l in "$dir"/*.json; do
      pid="${l##*/}"
      pid="${pid%.json}"
      [[ -n "${seen_products[$pid]:-}" ]] || rm -f "$l"
    done
    shopt -u nullglob
    if (( incomplete == 0 )); then
      touch "$marker"
    else
      rm -f "$marker"
    fi
  fi

  bs::status_line_clear "$quiet"
  echo "$new new (of which $incomplete incomplete)"
}

# Sets link $1 to product $2's image mtime, if both exist.
bs::_sync_link_time() {
  local link="$1" product_id="$2" image
  [[ -L "$link" ]] || return 0
  image="$(bs::image_file "$product_id")" || return 0
  touch -h -r "$image" -- "$link"
}

# Human-readable form of a bs::category_fetch_mode result ($1 mode, $2 epoch).
bs::describe_fetch_mode() {
  case "$1" in
    partial) echo "re-checking incomplete covers" ;;
    full) echo "full walk" ;;
    head) echo "head check, settling until $(date -d "@$2" +%F)" ;;
    *) echo "$1" ;;
  esac
}

bs::skipped_categories_summary() {
  local n="$1"
  echo "-- skipped $n synced categor$( ((n == 1)) && echo y || echo ies) not due for a full walk yet (--force to walk them anyway) --"
}
