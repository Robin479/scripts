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

# Registers $2 under $1's sha256 in image_hashes.json, then recomputes cover_status
# for every product sharing that hash -- placeholder if known/shared by 2+, else final.
bs::register_image_hash() {
  local hash="$1" product_id="$2"
  local hashes_file; hashes_file="$(bs::image_hashes_file)"

  local content
  content="$(jq --arg hash "$hash" --arg id "$product_id" \
    '.[$hash] = ((.[$hash] // []) + [$id] | unique)' \
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
}

# Total page count from a fetched category listing page.
bs::listing_page_count() {
  local html_file="$1"
  local n; n="$(xidel -s "$html_file" --extract-kind=xquery3 -e 'string((//div[@data-pages])[1]/@data-pages)' 2> /dev/null)"
  echo "${n:-1}"
}

# Every product on a fetched listing page, newest first: one {product_id, title, url} per line.
bs::listing_products() {
  local html_file="$1"
  # shellcheck disable=SC2016 # xidel xquery, not bash vars
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

# Fetches a product's detail page, extracts {title, image_url} (og:image).
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

# Finishes a new cover already sitting at images/<id>.<ext>: placeholder-hash
# classification, an atomic products/<id>.json write, category link (if $2
# given), series classification. Prints resulting cover_status on success.
bs::finalize_product() {
  local product_id="$1" category_id="$2" title="$3" source_url="$4" quiet="$5"

  local image_file; image_file="$(bs::image_file "$product_id")" || {
    bs::status_line_clear "$quiet"
    echo "error: no image file on disk for product $product_id" >&2
    return 1
  }

  local hash; hash="$(sha256sum "$image_file" | cut -d' ' -f1)"
  bs::register_image_hash "$hash" "$product_id"

  local product_file; product_file="$(bs::product_file "$product_id")"
  local existing_overrides="{}"
  [[ -f "$product_file" ]] && existing_overrides="$(jq -c '.overrides // {}' "$product_file")"

  local content
  if ! content="$(jq -n --arg product_id "$product_id" \
    --arg title "$title" --arg source_url "$source_url" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hash "$hash" \
    --argjson overrides "$existing_overrides" \
    '{
      product_id: $product_id,
      title: $title,
      source_url: (if $source_url == "" then null else $source_url end),
      image_sha256: $hash,
      fetched_at: $fetched_at,
      cover_status: "final",
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
  local product_id="$1" category_id="$2" title="$3" source_url="$4" reason="$5"

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
    --argjson overrides "$existing_overrides" \
    '{
      product_id: $product_id,
      title: (if $title == "" then null else $title end),
      source_url: (if $source_url == "" then null else $source_url end),
      image_sha256: null,
      fetched_at: $fetched_at,
      cover_status: "failed",
      failure_reason: $reason,
      overrides: $overrides
    }')" && bs::write_file "$product_file" "$content"

  bs::link_category_product "$category_id" "$product_id"
}

# True if any cached product in category $1 is recorded "failed".
bs::category_has_failures() {
  local category_id="$1" dir; dir="$(bs::category_dir "$category_id")/products"
  [[ -d "$dir" ]] || return 1
  shopt -s nullglob
  local pfile
  for pfile in "$dir"/*.json; do
    jq -e '.cover_status == "failed"' "$pfile" > /dev/null 2>&1 && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

# Fetches one new product end to end: detail page, cover download, then
# bs::finalize_product. A failure is recorded via bs::record_fetch_failure and
# reported to stderr. Prints "fetched"/"placeholder" on success.
bs::fetch_one_product() {
  local product_id="$1" category_id="$2" listing_title="$3" listing_url="$4" quiet="$5"

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
    bs::record_fetch_failure "$product_id" "$category_id" "$title" "$image_url" "$reason"
    return 1
  fi

  bs::finalize_product "$product_id" "$category_id" "$title" "$image_url" "$quiet"
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

  bs::finalize_product "$product_id" "$category_id" "$title" "" "$quiet"
}

# Marker: a fetch has walked category $1's products to the true end of pagination at least once.
bs::category_synced_marker() {
  local dir; dir="$(bs::category_dir "$1")/products"
  mkdir -p "$dir"
  echo "${dir}/.synced"
}

# Paginates category $1, fetching any product not already cached "final".
# Stops early at the first already-final product (releases are newest-first)
# unless $2 (force), or this category was never fully synced before, or it has
# any "failed" record (a stuck failure would otherwise never be retried).
# $3 (limit) caps new downloads; a limited run never marks the category synced.
# Prints "<new> new (of which <placeholder> placeholder)[, <skipped> already cached]".
bs::fetch_category() {
  local category_id="$1" force="$2" limit="$3" quiet="$4"
  local cat_file; cat_file="$(bs::category_file "$category_id")"
  [[ -f "$cat_file" ]] || { echo "error: unknown category $category_id -- run 'categories list' first" >&2; return 1; }
  local base_url; base_url="$(jq -r '.url' "$cat_file")"

  local synced_marker; synced_marker="$(bs::category_synced_marker "$category_id")"
  local already_synced=""
  if [[ -f "$synced_marker" ]] && ! bs::category_has_failures "$category_id"; then
    already_synced=1
  fi

  local new=0 placeholder=0 skipped=0 stop=0 limited=0 page=1 pages=1 pages_known=""
  local -A seen_products=()

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
      seen_products["$product_id"]=1

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
      outcome="$(bs::fetch_one_product "$product_id" "$category_id" "$title" "$url" "$quiet")" || continue
      new=$((new + 1))
      [[ "$outcome" == "placeholder" ]] && placeholder=$((placeholder + 1))
      bs::status_line_clear "$quiet"
      echo "$product_id -> $outcome ($title)"
    done < <(bs::listing_products "$html_file")

    rm -f "$html_file"
    page=$((page + 1))
  done

  [[ "$limited" -eq 0 ]] && touch "$synced_marker"

  # Prune stale product symlinks only when this run's own pagination never
  # exited early for any reason (force run, or first-ever backfill).
  if [[ "$stop" -eq 0 ]]; then
    local dir; dir="$(bs::category_dir "$category_id")/products"
    local link pid
    shopt -s nullglob
    for link in "$dir"/*.json; do
      pid="$(basename "$link" .json)"
      [[ -n "${seen_products[$pid]:-}" ]] || rm -f "$link"
    done
    shopt -u nullglob
  fi

  bs::status_line_clear "$quiet"
  local summary="$new new (of which $placeholder placeholder)"
  [[ "$skipped" -gt 0 ]] && summary="$summary, $skipped already cached (resuming an incomplete backfill)"
  echo "$summary"
}
