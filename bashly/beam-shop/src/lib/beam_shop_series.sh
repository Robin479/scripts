# Fallback item-number pattern when a series is defined without its own
# --item-pattern: the first run of digits anywhere in the title.
readonly BS_ITEM_PATTERN_DEFAULT='[0-9]+'

bs::series_root() {
  local dir; dir="$(bs::data_dir)/series"
  mkdir -p "$dir"
  echo "$dir"
}

bs::series_file() {
  echo "$(bs::series_root)/$1.json"
}

bs::series_view_dir() {
  echo "$(bs::series_root)/$1"
}

bs::require_series_file() {
  local id="$1" file
  file="$(bs::series_file "$id")"
  if [[ ! -f "$file" ]]; then
    echo "error: no series '$id' -- run 'series create $id --categories ...' first" >&2
    return 1
  fi
  echo "$file"
}

# Extracts the leading number of a trailing "N-M" range in $1 (a
# category's own name or slug, e.g. "PEGASOS 3350-3399" or
# "pegasos-3350-3399") -- used to auto-order a series' member categories
# chronologically. Prints nothing (not an error) if no such range exists.
bs::parse_range_start() {
  grep -oE '[0-9]+-[0-9]+$' <<< "$1" | tail -1 | cut -d- -f1
}

# Sorts a whitespace-separated list of category ids ($1) by each one's own
# parsed range start (bs::parse_range_start on its cached name). A
# category with no parsable range sorts last, in its given relative order.
bs::sort_categories_by_range() {
  local ids="$1" id name start
  for id in $ids; do
    name="$(jq -r '.name' "$(bs::category_file "$id")" 2> /dev/null)"
    start="$(bs::parse_range_start "$name")"
    printf '%s\t%s\n' "${start:-999999999}" "$id"
  done | sort -n -s -k1,1 | cut -f2
}

# Deduplicates a whitespace-separated list ($1), preserving first-seen
# order and dropping any blank entries.
bs::_dedup_words() {
  tr -s ' ' '\n' <<< "$1" | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

# Splits $1 on commas into a deduped, order-preserving, space-separated
# list -- the common normalization every one of --categories/
# --add-categories/--resolutions/--add-resolutions needs before use.
bs::_normalize_csv() {
  bs::_dedup_words "$(tr ',' ' ' <<< "$1")"
}

# Removes every item in $2 (space-separated) from $1 (space-separated),
# preserving $1's own relative order. Generic -- used for both category
# ids and resolution specs.
bs::_subtract_list() {
  local from="$1" remove="$2" kept="" item ritem skip
  for item in $from; do
    skip=""
    for ritem in $remove; do
      [[ "$item" == "$ritem" ]] && { skip=1; break; }
    done
    [[ -z "$skip" ]] && kept="$kept $item"
  done
  echo "$kept"
}

# Writes series $1's definition file from already-finalized values --
# shared by bs::series_create and bs::series_edit, which each work out
# $2 (space-separated category ids)/$3 (name)/$4 (item_pattern)/$5
# (space-separated resolution specs, may be empty) their own way first.
bs::_write_series() {
  local id="$1" ids="$2" name="$3" item_pattern="$4" resolutions="$5"
  local ids_json resolutions_json
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted -- both are plain space-separated lists, one entry per resulting line (an empty $resolutions still yields one blank line, filtered out by select(length>0) below)
  ids_json="$(printf '%s\n' $ids | jq -R . | jq -s .)"
  # shellcheck disable=SC2086
  resolutions_json="$(printf '%s\n' $resolutions | jq -R 'select(length > 0)' | jq -s .)"
  jq -n --arg id "$id" --arg name "$name" --argjson category_ids "$ids_json" \
    --arg item_pattern "$item_pattern" --argjson resolutions "$resolutions_json" \
    '{series_id: $id, name: $name, category_ids: $category_ids,
      item_pattern: (if $item_pattern == "" then null else $item_pattern end),
      resolutions: $resolutions}' \
    > "$(bs::series_file "$id")"
}

# Creates a brand-new series (overwrites if $1 already exists -- the
# command script is expected to route an existing id to bs::series_edit
# instead, this doesn't check). $2 categories_csv (required by the caller,
# not here), $3 resolutions_csv ("" for none -- see bs::resize_series),
# $4 name ("" defaults to the first category's own name), $5 item_pattern
# ("" falls back to BS_ITEM_PATTERN_DEFAULT at classification time, not
# baked in here, so a later global default change applies retroactively),
# $6 order (auto|given).
bs::series_create() {
  local id="$1" categories_csv="$2" resolutions_csv="$3" name="$4" item_pattern="$5" order="$6"
  local ids; ids="$(bs::_normalize_csv "$categories_csv")"

  if [[ "$order" == "auto" ]]; then
    ids="$(bs::sort_categories_by_range "$ids" | tr '\n' ' ')"
  fi

  if [[ -z "$name" ]]; then
    # shellcheck disable=SC2086 # word-splitting is exactly what's wanted here
    set -- $ids
    name="$(jq -r '.name' "$(bs::category_file "$1")" 2> /dev/null)"
  fi

  local resolutions; resolutions="$(bs::_normalize_csv "$resolutions_csv")"

  bs::_write_series "$id" "$ids" "$name" "$item_pattern" "$resolutions"
}

# Updates an existing series -- merging with (never silently clobbering)
# whatever isn't explicitly given this call, so "add one more cycle" or
# "add another output size" doesn't require retyping everything else.
# Errors (via bs::require_series_file) if $1 isn't already a series.
#   $2 categories_csv     -- full replacement of the category list; "" to
#                            leave the current membership alone
#   $3 add_categories_csv  -- category ids to merge into the current list
#   $4 remove_categories_csv -- category ids to drop from it
#   $5 resolutions_csv     -- full replacement of the resolution list; ""
#                            to leave it alone
#   $6 add_resolutions_csv -- resize specs to merge into the current list
#   $7 remove_resolutions_csv -- resize specs to drop from it
#   $8 name               -- "" keeps the existing name
#   $9 item_pattern       -- "" keeps the existing pattern
#   $10 order             -- applied to the resulting category list either way
# $2 is mutually exclusive with $3/$4, and $5 with $6/$7 -- validated by
# the command script, not here (this just trusts whichever it's given).
bs::series_edit() {
  local id="$1" categories_csv="$2" add_categories_csv="$3" remove_categories_csv="$4"
  local resolutions_csv="$5" add_resolutions_csv="$6" remove_resolutions_csv="$7"
  local name="$8" item_pattern="$9" order="${10}"

  local file; file="$(bs::require_series_file "$id")" || return 1
  local existing_ids existing_name existing_pattern existing_resolutions
  existing_ids="$(jq -r '.category_ids[]' "$file" | tr '\n' ' ')"
  existing_name="$(jq -r '.name' "$file")"
  existing_pattern="$(jq -r '.item_pattern // empty' "$file")"
  existing_resolutions="$(jq -r '(.resolutions // [])[]' "$file" | tr '\n' ' ')"

  local ids
  if [[ -n "$categories_csv" ]]; then
    ids="$(bs::_normalize_csv "$categories_csv")"
  else
    ids="$existing_ids"
    [[ -n "$add_categories_csv" ]] && ids="$ids $(tr ',' ' ' <<< "$add_categories_csv")"
    [[ -n "$remove_categories_csv" ]] && ids="$(bs::_subtract_list "$ids" "$(tr ',' ' ' <<< "$remove_categories_csv")")"
    ids="$(bs::_dedup_words "$ids")"
  fi

  if [[ -z "${ids// /}" ]]; then
    echo "error: a series must have at least one category" >&2
    return 1
  fi

  if [[ "$order" == "auto" ]]; then
    ids="$(bs::sort_categories_by_range "$ids" | tr '\n' ' ')"
  fi

  local resolutions
  if [[ -n "$resolutions_csv" ]]; then
    resolutions="$(bs::_normalize_csv "$resolutions_csv")"
  else
    resolutions="$existing_resolutions"
    [[ -n "$add_resolutions_csv" ]] && resolutions="$resolutions $(tr ',' ' ' <<< "$add_resolutions_csv")"
    [[ -n "$remove_resolutions_csv" ]] && resolutions="$(bs::_subtract_list "$resolutions" "$(tr ',' ' ' <<< "$remove_resolutions_csv")")"
    resolutions="$(bs::_dedup_words "$resolutions")"
  fi

  [[ -n "$name" ]] || name="$existing_name"
  [[ -n "$item_pattern" ]] || item_pattern="$existing_pattern"

  bs::_write_series "$id" "$ids" "$name" "$item_pattern" "$resolutions"
}

bs::series_item_pattern() {
  local id="$1" pattern
  pattern="$(jq -r '.item_pattern // empty' "$(bs::series_file "$id")" 2> /dev/null)"
  echo "${pattern:-$BS_ITEM_PATTERN_DEFAULT}"
}

# Prints series $1's own resize resolution specs, one per line (empty if
# none defined -- bs::resize_series then falls back to the
# image_width/_height/_format config keys).
bs::series_resolutions() {
  local id="$1"
  jq -r '(.resolutions // [])[]' "$(bs::series_file "$id")" 2> /dev/null
}

# Validates $1, a comma-separated list of resize geometry specs -- just
# enough to keep them from corrupting the space-separated list
# representation used internally (a spec is passed straight through to
# ImageMagick's -resize, so its own grammar isn't beam-shop's to police).
# Prints nothing and returns 0 if $1 is empty or every entry is
# whitespace-free; otherwise names the bad entry on stderr and returns 1.
bs::validate_resize_specs() {
  local csv="$1" spec
  IFS=',' read -r -a specs <<< "$csv"
  for spec in "${specs[@]}"; do
    if [[ "$spec" == *[[:space:]]* ]]; then
      echo "error: a resize spec can't contain whitespace: '$spec'" >&2
      return 1
    fi
  done
  return 0
}

# Prints every defined series' own id, one per line, in filename order.
bs::all_series_ids() {
  local f
  for f in "$(bs::series_root)"/*.json; do
    [[ -e "$f" ]] || continue
    basename "$f" .json
  done
}

# Prints series $1's own member category ids, one per line, in the order
# stored by 'series create'/'series edit' (already chronological if
# --order auto was used). Errors out (via bs::require_series_file) if the
# series is unknown.
bs::series_category_ids() {
  local id="$1" file
  file="$(bs::require_series_file "$id")" || return 1
  jq -r '.category_ids[]' "$file"
}

# Which series (if any) owns $1 (a category id) -- the first defined
# series whose category_ids includes it. Prints nothing if none does.
bs::series_for_category() {
  local category_id="$1" file
  for file in "$(bs::series_root)"/*.json; do
    [[ -e "$file" ]] || continue
    if jq -e --arg c "$category_id" '.category_ids | index($c)' "$file" > /dev/null 2>&1; then
      jq -r '.series_id' "$file"
      return 0
    fi
  done
  return 1
}

# Finds the already-cached product classified into series $1 at item
# number $2, if any -- prints its {product_id, category_id, title} as one
# JSON object; prints nothing (not an error) and returns 1 if no such
# record exists yet. This can only ever resolve an item that's been
# *fetched* at least once (its item_number is derived at fetch time, not
# computable from the series/number alone) -- so it's a shortcut for
# 'covers import' to re-supply a cover for a 'broken' bs::series_audit
# finding (record intact, image file gone), never for a 'missing' one
# (nothing to look up). Grep-prefiltered by series id first (same
# technique as bs::series_remove/bs::series_audit) before checking the
# item_number match with jq, so this stays fast even across thousands of
# cached products.
bs::find_series_item() {
  local series_id="$1" item_number="$2"
  local products_dir; products_dir="$(bs::products_dir)"
  local pfile
  while IFS= read -r pfile; do
    [[ -n "$pfile" ]] || continue
    if jq -e --arg id "$series_id" --argjson n "$item_number" \
        '.series_id == $id and .item_number == $n' "$pfile" > /dev/null 2>&1; then
      jq -c '{product_id, category_id, title}' "$pfile"
      return 0
    fi
  done < <(grep -rlF "\"series_id\": \"$series_id\"" "$products_dir" 2> /dev/null)
  return 1
}

# Removes series $1's own definition and everything derived from it
# (its symlink view, its resize output) -- never touches canonical
# products/images data, since that's real scraped fact, not part of the
# series mapping. Un-classifies (series_id/item_number -> null) any
# product currently attributed to this series, so a later series redefined
# under the same id starts from a clean slate rather than silently
# inheriting a stale classification (grep-prefiltered so this stays cheap
# even with thousands of cached products: jq only runs on files that
# actually mention this series id, not every file). Errors if $1 isn't a
# defined series.
bs::series_remove() {
  local id="$1"
  local file; file="$(bs::series_file "$id")"
  [[ -f "$file" ]] || { echo "$id -> not found" >&2; return 1; }

  rm -f "$file"
  rm -rf "$(bs::series_view_dir "$id")"
  rm -rf "$(bs::series_resized_dir "$id")"

  local products_dir; products_dir="$(bs::products_dir)"
  local pfile tmp
  while IFS= read -r pfile; do
    [[ -n "$pfile" ]] || continue
    tmp="$(mktemp)"
    jq '.series_id = null | .item_number = null' "$pfile" > "$tmp" && mv "$tmp" "$pfile"
  done < <(grep -rlF "\"series_id\": \"$id\"" "$products_dir" 2> /dev/null)
}

# Rebuilds the symlink view for one series from canonical products/images
# data -- deletes and recreates series/<id>/ entirely, so it always
# exactly reflects current data (no stale entries left behind after a
# product's classification changes). Entries are named by zero-padded
# item number alone (e.g. "00049.jpg"/"00049.json") -- deliberately no
# title/slug in the filename, per explicit direction, which also means
# this loop needs no per-row string processing at all, just symlinks. $2
# (quiet, see bs::fetch_quiet) suppresses the self-updating status line.
#
# Deliberately kept to a small, fixed number of subprocesses regardless
# of series size, same reasoning (and same fix) as bs::series_audit --
# confirmed directly: an earlier version that ran a `jq -e` filter check
# against *every* grep-prefiltered candidate (matching or not), then more
# `jq -r` calls per match plus a `tr`+`sed` slug pipeline, took minutes on
# a real ~2400-product series -- every `covers import`/`covers fetch`
# call ends with a relink, so this wasn't a rare-path cost. One `jq -r
# ... | @tsv` call both filters and extracts every matching row in one
# pass (replacing the per-candidate `jq -e` + per-match `jq -r` calls),
# and one directory listing builds a product-id -> actual-image-filename
# lookup (replacing a filesystem glob, bs::image_file, per matching row).
bs::series_relink() {
  local id="$1" quiet="$2" file
  file="$(bs::require_series_file "$id")" || return 1

  local view_dir; view_dir="$(bs::series_view_dir "$id")"
  rm -rf "$view_dir"
  mkdir -p "$view_dir"

  local products_dir; products_dir="$(bs::products_dir)"
  local candidates=()
  while IFS= read -r pfile; do
    [[ -n "$pfile" ]] && candidates+=("$pfile")
  done < <(grep -rlF "\"series_id\": \"$id\"" "$products_dir" 2> /dev/null)
  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo 0
    return 0
  fi

  local images_dir; images_dir="$(bs::images_dir)"
  local -A image_for=()
  local f base
  shopt -s nullglob
  for f in "$images_dir"/*; do
    base="${f##*/}"
    image_for["${base%.*}"]="$base"
  done
  shopt -u nullglob

  # item_number != null matters on its own, not just alongside
  # cover_status -- a product can be classified into this series (its
  # category maps here) yet still fail *item-number* classification
  # (title didn't match item_pattern, or item_pattern itself matched
  # something non-numeric -- see bs::classify_item_number) while still
  # being a perfectly good "final" cover; without this check such a
  # product got a bogus "00000-..." view entry instead of being left out
  # (confirmed directly: printf '%05d' on the literal string "null",
  # which is what `jq -r '.item_number'` prints for a JSON null).
  local rows; rows="$(jq -r --arg id "$id" \
    'select(.series_id == $id and .cover_status == "final" and .item_number != null) |
     [.product_id, (.item_number | tostring)] | @tsv' \
    "${candidates[@]}")"

  local linked=0 processed=0
  local product_id item_number padded image_file ext
  while IFS=$'\t' read -r product_id item_number; do
    [[ -n "$product_id" ]] || continue
    processed=$((processed + 1))
    bs::status_line "series $id: relinking [$processed] $product_id..." "$quiet"

    image_file="${image_for[$product_id]:-}"
    [[ -n "$image_file" ]] || continue
    ext="${image_file##*.}"

    padded="$(printf '%05d' "$item_number")"
    ln -s "../../images/${image_file}" "$view_dir/${padded}.${ext}"
    ln -s "../../products/${product_id}.json" "$view_dir/${padded}.json"
    linked=$((linked + 1))
  done <<< "$rows"

  bs::status_line_clear "$quiet"
  echo "$linked"
}

# Reports problems in series $1's cached data, purely from local
# metadata -- no network access, so this also works fully offline. Emits
# one JSON object per finding ({item_number, kind, product_id, title},
# item_number/product_id/title null where they don't apply), unsorted
# (the caller sorts). Three kinds:
#  - "missing": an integer between the series' own observed min and max
#    item_number with no cached product at all -- genuinely never
#    reached by any fetch attempt. Nothing to resolve a product id from
#    here (see 'covers import', which needs the --product/--category/
#    --title form for this one, not its --series/--item shortcut).
#  - "broken": a cached product classified into this series with either
#    cover_status "failed" (a fetch attempt was made and recorded exactly
#    why it didn't get a cover -- shown appended to its title -- e.g. a
#    404'd cover url; see bs::record_fetch_failure) or cover_status
#    "final" with no actual images/<id>.<ext> file on disk (deleted after
#    the fact, or some other inconsistency). Both report as the same kind
#    since the fix is identical either way: 'covers import', including
#    its --series/--item shortcut, which resolves against either kind of
#    record equally (both have a real product_id/category_id/title
#    already on file) -- cover_status itself still distinguishes the two
#    root causes for anyone inspecting the raw JSON.
#  - "placeholder": a cached product still stuck at cover_status
#    "placeholder" -- lower severity than the other two (the real cover
#    may simply not exist upstream yet), listed for visibility.
# Errors out (via bs::require_series_file) if the series is unknown.
#
# Deliberately kept to a small, fixed number of subprocesses regardless
# of series size -- confirmed directly: an earlier version that called
# jq once per field per candidate (5 calls) plus a per-candidate
# bs::image_file filesystem glob took *minutes* on Perry Rhodan's
# ~2000-cached-product series, when it should be near-instant for a
# purely local, no-network operation. Two things make that possible:
#  - one directory listing (not one glob per product) builds a
#    product-id -> "has an image file" lookup up front;
#  - one jq invocation extracts every candidate as a TSV row (jq's
#    default multi-document input streams one row per matching file),
#    and the classification loop over those rows is then pure bash
#    (string comparisons + associative-array lookups, no subprocess per
#    row at all) -- accumulating plain TSV text for every finding, which
#    a single final jq call converts into this function's real
#    JSON-lines contract, instead of one `jq -n` per finding.
bs::series_audit() {
  local id="$1"
  bs::require_series_file "$id" > /dev/null || return 1

  local products_dir; products_dir="$(bs::products_dir)"
  local candidates=()
  while IFS= read -r pfile; do
    [[ -n "$pfile" ]] && candidates+=("$pfile")
  done < <(grep -rlF "\"series_id\": \"$id\"" "$products_dir" 2> /dev/null)
  [[ "${#candidates[@]}" -eq 0 ]] && return 0

  # "Has an image file" lookup from one directory listing, not one
  # filesystem glob (bs::image_file) per candidate below.
  local images_dir; images_dir="$(bs::images_dir)"
  local -A has_image=()
  local f base
  shopt -s nullglob
  for f in "$images_dir"/*; do
    base="$(basename "$f")"
    has_image["${base%.*}"]=1
  done
  shopt -u nullglob

  # One jq invocation across every candidate file (not one per file, and
  # not one per field) -- jq's default input handling reads each file as
  # its own top-level value, so this streams one TSV row per matching
  # file. -1/"" stand in for a null item_number/failure_reason -- real
  # item numbers are always positive, so -1 is an unambiguous sentinel
  # a plain bash string comparison can check with no further jq calls.
  local rows; rows="$(jq -r --arg id "$id" \
    'select(.series_id == $id) |
     [.product_id, (.title // ""), ((.item_number // -1) | tostring), .cover_status, (.failure_reason // "")] | @tsv' \
    "${candidates[@]}")"

  local out=""
  local -A seen=()
  local min="" max=""
  local product_id title item_number cover_status failure_reason display_title
  while IFS=$'\t' read -r product_id title item_number cover_status failure_reason; do
    [[ -n "$product_id" ]] || continue

    # Both a stuck "failed" attempt (never had an image at all) and a
    # "final" record whose image file has since vanished are reported as
    # the same user-facing "broken" kind -- the actionable fix is
    # identical either way ('covers import', possibly via its
    # --series/--item shortcut, which resolves against either kind of
    # record equally). cover_status itself still distinguishes the real
    # root cause for anyone inspecting the raw JSON.
    if [[ "$cover_status" == "failed" ]] \
        || { [[ "$cover_status" == "final" ]] && [[ -z "${has_image[$product_id]:-}" ]]; }; then
      display_title="$title"
      [[ -n "$failure_reason" ]] && display_title="$title (reason: $failure_reason)"
      out+="${item_number}"$'\t'"broken"$'\t'"$product_id"$'\t'"$display_title"$'\n'
    elif [[ "$cover_status" == "placeholder" ]]; then
      out+="${item_number}"$'\t'"placeholder"$'\t'"$product_id"$'\t'"$title"$'\n'
    fi

    if [[ "$item_number" != "-1" ]]; then
      seen["$item_number"]=1
      [[ -z "$min" || "$item_number" -lt "$min" ]] && min="$item_number"
      [[ -z "$max" || "$item_number" -gt "$max" ]] && max="$item_number"
    fi
  done <<< "$rows"

  if [[ -n "$min" ]]; then
    local n
    for (( n = min; n <= max; n++ )); do
      [[ -n "${seen[$n]:-}" ]] || out+="${n}"$'\t'"missing"$'\t'"-1"$'\t'""$'\n'
    done
  fi

  [[ -n "$out" ]] || return 0

  # Single jq call converts the whole accumulated batch into this
  # function's real JSON-lines contract, instead of one `jq -n` per
  # finding.
  jq -R -c 'split("\t") | {
    item_number: (if .[0] == "-1" then null else (.[0] | tonumber) end),
    kind: .[1],
    product_id: (if .[2] == "-1" then null else .[2] end),
    title: (if .[3] == "" then null else .[3] end)
  }' <<< "${out%$'\n'}"
}
