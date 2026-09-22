# Default root category to crawl from when nothing else is configured --
# the shop's whole "Serien & Abo" section.
readonly BS_DISCOVERY_ROOT_URL_DEFAULT="https://www.beam-shop.de/serien-abo/"

# Default for the category_cache_ttl config key (seconds), used when unset.
# Unlike a book/product's cache (immutable once fetched), a category's own
# child list genuinely does change over time -- e.g. a new Perry Rhodan
# cycle is added roughly every ~50 issues -- so this needs a real TTL, not
# just "cached forever until --refresh".
readonly BS_CATEGORY_CACHE_TTL_DEFAULT=$((30 * 24 * 3600))

bs::categories_dir() {
  local dir; dir="$(bs::data_dir)/categories"
  mkdir -p "$dir"
  echo "$dir"
}

bs::category_file() {
  echo "$(bs::categories_dir)/$1.json"
}

bs::discovery_root_url() {
  bs::config_get discovery_root_url "$BS_DISCOVERY_ROOT_URL_DEFAULT"
}

# Extracts every sidebar navigation link on a fetched category page as
# {id, url, name} triples (url absolute, name whitespace-normalized).
# Shopware only expands this sidebar tree one level below (and one level
# alongside) whatever category the page actually belongs to -- so this is
# never a full-site tree, just whatever's currently in view. Confirmed
# directly: fetching a series' own page (e.g. Perry Rhodan Erstauflage)
# reveals its ~46 cycles *and* its sibling series within the same genre,
# but not other genres, and not a genre landing page's own children
# either -- see bs::extract_menu_links for the one level this can't reach.
bs::extract_nav_links() {
  local html_file="$1"
  # shellcheck disable=SC2016 # single-quoted on purpose -- this is an xidel xquery program, its own $-variables aren't bash's
  # A category that itself has sub-categories gets extra classes on this
  # same link (e.g. "navigation--link link--go-forward has--sub-categories",
  # or "navigation--link is--active" for the current page's own entry) --
  # confirmed directly (Perry Rhodan Erstauflage's link in
  # /serien-abo/science-fiction/ is class="navigation--link link--go-forward",
  # not the bare class), so this must match the class *token*, not the
  # whole attribute string, or every parent-of-a-series category silently
  # vanishes from the crawl.
  xidel -s "$html_file" --extract-kind=xquery3 -e '
    [for $a in //a[contains(concat(" ", normalize-space(@class), " "), " navigation--link ")]
     return {
       "id": string($a/@data-categoryId),
       "url": string($a/@href),
       "name": normalize-space(string($a/@title))
     }]
  ' --output-format=json-wrapped 2> /dev/null | jq -c '.[0][]'
}

# Extracts the sitewide mega-menu's links (present in every page's header,
# server-rendered) as {id, url, name} triples -- id is always "" here,
# unlike bs::extract_nav_links, since this menu carries no
# data-categoryId at all. This is the *only* place the top-level genre
# list (science-fiction, fantasy, ...) is discoverable, so
# bs::crawl_children uses this specifically for the discovery root, and
# bs::filter_direct_children synthesizes an id from the url's own slug in
# that case.
bs::extract_menu_links() {
  local html_file="$1"
  # shellcheck disable=SC2016 # single-quoted on purpose -- this is an xidel xquery program, its own $-variables aren't bash's
  xidel -s "$html_file" --extract-kind=xquery3 -e '
    [for $a in //a[@class="menu--list-item-link"]
     return {
       "id": "",
       "url": string($a/@href),
       "name": normalize-space(string($a/@title))
     }]
  ' --output-format=json-wrapped 2> /dev/null | jq -c '.[0][]'
}

# Given a fetched page's links (one JSON {id, url, name} object per line,
# on stdin) and a parent url, prints {id, url, name} for each direct child
# -- a link whose url starts with $parent_url and has exactly one more
# path segment (excludes the parent's own self-link, and excludes
# deeper-nested links that happen to share the prefix). $2 ("synthesize"),
# when set, fills in a missing id from the url's own trailing slug instead
# of dropping the entry -- only the root-level mega-menu extraction needs
# this, since it carries no data-categoryId at all.
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

# Crawls $2 (a category's own url) for its direct child categories,
# caches each one's own {category_id, name, url, parent_id} in
# categories/<id>.json, and prints the same set of child ids, one per
# line. $1 is the parent's own category id, or "" for the discovery root
# (which has no numeric id of its own, and whose own children -- the
# genre list -- only ever appear in the sitewide mega-menu, never the
# sidebar; see bs::extract_menu_links).
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

    echo "$id"
  done < <("$extractor" "$html_file" | bs::filter_direct_children "$parent_url" "$synthesize")
}

# True (0, prints nothing) if $1's cached child-list marker exists and is
# still within its `category_cache_ttl` config seconds
# (BS_CATEGORY_CACHE_TTL_DEFAULT if unset) -- false (1) if missing or
# stale. Same `find -newermt` single-check idiom as gr::book_fresh in
# bashly/goodreads (handles "missing" and "stale" as one case: empty
# output either way means "needs a re-crawl").
bs::category_children_fresh() {
  local cache_marker="$1" ttl threshold fresh
  [[ -f "$cache_marker" ]] || return 1

  ttl="$(bs::config_get category_cache_ttl "$BS_CATEGORY_CACHE_TTL_DEFAULT")"
  threshold="$(date -d "-${ttl} seconds" +'%Y-%m-%d %H:%M:%S')"
  fresh="$(find "$cache_marker" -newermt "$threshold" 2> /dev/null)" || true
  [[ -n "$fresh" ]]
}

# Finds an already-cached category id whose own url is exactly $1 --
# empty if none is cached yet.
bs::category_id_for_url() {
  local url="$1" f
  for f in "$(bs::categories_dir)"/*.json; do
    [[ -e "$f" ]] || continue
    if [[ "$(jq -r '.url' "$f" 2> /dev/null)" == "$url" ]]; then
      jq -r '.category_id' "$f"
      return 0
    fi
  done
  return 1
}

# Prints the children of $1 (a category id, or, as an escape hatch for
# anything the sitewide menu/sidebar crawl genuinely can't reach on its
# own, a raw https:// url), crawling live if there's no cached result
# within category_cache_ttl (or --refresh forces it regardless of age).
# With no argument, crawls/reads the configured discovery root's own
# direct children (the genre list).
bs::category_children() {
  local parent_id="${1:-}" refresh="${2:-}"

  local parent_url
  if [[ -z "$parent_id" ]]; then
    parent_url="$(bs::discovery_root_url)"
  elif [[ "$parent_id" == http*://* ]]; then
    # A raw url: register it as a category of its own first (reusing an
    # existing id if this exact url is already cached under one) so
    # later commands can refer to it by id from here on.
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

  local cache_marker; cache_marker="$(bs::categories_dir)/.children-of-${parent_id:-root}"
  if [[ -z "$refresh" ]] && bs::category_children_fresh "$cache_marker"; then
    cat "$cache_marker"
    return 0
  fi

  local ids; ids="$(bs::crawl_children "$parent_id" "$parent_url")" || return 1
  echo "$ids" > "$cache_marker"
  echo "$ids"
}
