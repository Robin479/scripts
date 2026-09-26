readonly BS_DISCOVERY_ROOT_URL_DEFAULT="https://www.beam-shop.de/serien-abo/"
readonly BS_CATEGORY_CACHE_TTL_DEFAULT=$((30 * 24 * 3600))

bs::categories_dir() {
  local dir; dir="$(bs::data_dir)/categories"
  mkdir -p "$dir"
  echo "$dir"
}

# Every category (root genre or not) lives flatly under categories/, never nested under its parent.
bs::category_dir() {
  local dir; dir="$(bs::categories_dir)/$1"
  mkdir -p "$dir"
  echo "$dir"
}

bs::category_file() {
  echo "$(bs::category_dir "$1")/meta.json"
}

# Folder a category's children get symlinked into: $1's own folder, or categories/.root/ for the nil-parent.
bs::category_children_dir() {
  local parent_id="$1"
  if [[ -z "$parent_id" ]]; then
    local dir; dir="$(bs::categories_dir)/.root"
    mkdir -p "$dir"
    echo "$dir"
  else
    bs::category_dir "$parent_id"
  fi
}

# Lists $1's already-cached children, one id per line (symlink basenames).
bs::list_category_children() {
  local dir="$1" f
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ -L "$f" ]] && basename "$f"
  done
  shopt -u nullglob
}

# Sorts category ids (stdin) by leading numeric prefix, then alphabetically.
bs::_sort_category_ids() {
  local id num alpha
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    num="$(grep -oE '^[0-9]+' <<< "$id")"
    alpha="${id#"$num"}"
    printf '%s\t%s\t%s\n' "${num:-0}" "$alpha" "$id"
  done | sort -t $'\t' -k1,1n -k2,2 | cut -f3
}

# Records that product $2 was found under category $1 (a plain symlink).
bs::link_category_product() {
  local category_id="$1" product_id="$2"
  local dir; dir="$(bs::category_dir "$category_id")/products"
  mkdir -p "$dir"
  ln -sf "../../../products/${product_id}.json" "${dir}/${product_id}.json"
}

# Every category id product $1 is currently linked from, one per line.
bs::categories_for_product() {
  local product_id="$1" d
  shopt -s nullglob
  for d in "$(bs::categories_dir)"/*/; do
    [[ -f "${d}products/${product_id}.json" ]] && basename "$d"
  done
  shopt -u nullglob
}

# Prints "product_id\x01category_id" for every (product, category) link -- the full set,
# for every product at once (one pass per category, not per product).
bs::_all_categories_for_products() {
  local d cid pfile pid
  shopt -s nullglob
  for d in "$(bs::categories_dir)"/*/; do
    cid="${d%/}"
    cid="${cid##*/}"
    for pfile in "${d}products/"*.json; do
      pid="${pfile##*/}"
      pid="${pid%.json}"
      printf '%s\x01%s\n' "$pid" "$cid"
    done
  done
  shopt -u nullglob
}

bs::discovery_root_url() {
  bs::config_get discovery_root_url "$BS_DISCOVERY_ROOT_URL_DEFAULT"
}

# Extracts a fetched category page's sidebar nav links as {id, url, name} triples.
bs::extract_nav_links() {
  local html_file="$1"
  # shellcheck disable=SC2016 # xidel xquery, not bash vars
  xidel -s "$html_file" --extract-kind=xquery3 -e '
    [for $a in //a[contains(concat(" ", normalize-space(@class), " "), " navigation--link ")]
     return {
       "id": string($a/@data-categoryId),
       "url": string($a/@href),
       "name": normalize-space(string($a/@title))
     }]
  ' --output-format=json-wrapped 2> /dev/null | jq -c '.[0][]'
}

# Extracts the sitewide mega-menu's links as {id, url, name} triples (id always "").
bs::extract_menu_links() {
  local html_file="$1"
  # shellcheck disable=SC2016 # xidel xquery, not bash vars
  xidel -s "$html_file" --extract-kind=xquery3 -e '
    [for $a in //a[@class="menu--list-item-link"]
     return {
       "id": "",
       "url": string($a/@href),
       "name": normalize-space(string($a/@title))
     }]
  ' --output-format=json-wrapped 2> /dev/null | jq -c '.[0][]'
}

# Given fetched links (stdin) and a parent url, prints {id, url, name} for each direct
# child. $2 (synthesize), if set, derives a missing id from the url's own slug.
bs::filter_direct_children() {
  local parent_url="$1" synthesize="${2:-}"
  jq -s -c --arg parent "$parent_url" --arg synth "$synthesize" '
    [.[] |
     .url = (if (.url | startswith("http")) then .url else "https://www.beam-shop.de" + .url end) |
     select(.url | startswith($parent)) |
     .rest = (.url | ltrimstr($parent)) |
     select(.rest | test("^[^/]+/$")) |
     (if .id == "" and $synth != "" then .id = (.rest | rtrimstr("/")) else . end) |
     select(.id != "") |
     del(.rest)] | unique_by(.id) | .[]
  '
}

# Crawls $2 (parent url) for direct child categories, caches each under
# categories/<id>/meta.json, symlinks it into the parent's children-dir, prints
# each child id. $1 is the parent's own id, or "" for the discovery root.
# Self-correcting: any stale child symlink not among this run's children is removed.
bs::crawl_children() {
  local parent_id="$1" parent_url="$2"
  local html_file; html_file="$(mktemp)"
  trap 'rm -f "$html_file"; trap - RETURN' RETURN

  bs::http_get "$parent_url" > "$html_file" || return 1

  local extractor synthesize=""
  if [[ -z "$parent_id" ]]; then
    extractor="bs::extract_menu_links"
    synthesize="1"
  else
    extractor="bs::extract_nav_links"
  fi

  local children_dir; children_dir="$(bs::category_children_dir "$parent_id")"
  local new_ids=()

  local child_json
  while IFS= read -r child_json; do
    local id name url
    id="$(jq -r '.id' <<< "$child_json")"
    name="$(jq -r '.name' <<< "$child_json")"
    url="$(jq -r '.url' <<< "$child_json")"

    jq -n --arg id "$id" --arg name "$name" --arg url "$url" \
      --arg parent_id "$parent_id" \
      '{category_id: $id, name: $name, url: $url, parent_id: (if $parent_id == "" then null else $parent_id end)}' \
      > "$(bs::category_file "$id")"

    ln -sf "../${id}" "${children_dir}/${id}"
    new_ids+=("$id")
    echo "$id"
  done < <("$extractor" "$html_file" | bs::filter_direct_children "$parent_url" "$synthesize")

  local old base keep nid
  shopt -s nullglob
  for old in "$children_dir"/*; do
    [[ -L "$old" ]] || continue
    base="$(basename "$old")"
    keep=""
    for nid in "${new_ids[@]}"; do
      [[ "$base" == "$nid" ]] && { keep=1; break; }
    done
    [[ -z "$keep" ]] && rm -f "$old"
  done
  shopt -u nullglob
}

# True if $1's cached child-list marker exists and is within category_cache_ttl.
bs::category_children_fresh() {
  local cache_marker="$1" ttl threshold fresh
  [[ -f "$cache_marker" ]] || return 1

  ttl="$(bs::config_get category_cache_ttl "$BS_CATEGORY_CACHE_TTL_DEFAULT")"
  threshold="$(date -d "-${ttl} seconds" +'%Y-%m-%d %H:%M:%S')"
  fresh="$(find "$cache_marker" -newermt "$threshold" 2> /dev/null)" || true
  [[ -n "$fresh" ]]
}

# Finds an already-cached category id whose own url is exactly $1.
bs::category_id_for_url() {
  local url="$1" f
  for f in "$(bs::categories_dir)"/*/meta.json; do
    [[ -e "$f" ]] || continue
    if [[ "$(jq -r '.url' "$f" 2> /dev/null)" == "$url" ]]; then
      jq -r '.category_id' "$f"
      return 0
    fi
  done
  return 1
}

# Children of $1 (a category id, or a raw https:// url as an escape hatch), crawling
# live if not cached within category_cache_ttl (or --refresh). No argument: the
# discovery root's own direct children (the genre list).
bs::category_children() {
  local parent_id="${1:-}" refresh="${2:-}"

  local parent_url
  if [[ -z "$parent_id" ]]; then
    parent_url="$(bs::discovery_root_url)"
  elif [[ "$parent_id" == http*://* ]]; then
    parent_url="$parent_id"
    local existing_id; existing_id="$(bs::category_id_for_url "$parent_url")"
    if [[ -n "$existing_id" ]]; then
      parent_id="$existing_id"
    else
      local name; name="$(basename "${parent_url%/}")"
      parent_id="$name"
      jq -n --arg id "$parent_id" --arg name "$name" --arg url "$parent_url" \
        '{category_id: $id, name: $name, url: $url, parent_id: null}' \
        > "$(bs::category_file "$parent_id")"
    fi
  else
    local parent_file; parent_file="$(bs::category_file "$parent_id")"
    [[ -f "$parent_file" ]] || { echo "error: unknown category $parent_id -- run 'categories list' first, or pass a full https:// url directly" >&2; return 1; }
    parent_url="$(jq -r '.url' "$parent_file")"
  fi

  local children_dir; children_dir="$(bs::category_children_dir "$parent_id")"
  local cache_marker="${children_dir}/.synced"
  if [[ -z "$refresh" ]] && bs::category_children_fresh "$cache_marker"; then
    bs::list_category_children "$children_dir" | bs::_sort_category_ids
    return 0
  fi

  local ids; ids="$(bs::crawl_children "$parent_id" "$parent_url")" || return 1
  touch "$cache_marker"
  bs::_sort_category_ids <<< "$ids"
}
