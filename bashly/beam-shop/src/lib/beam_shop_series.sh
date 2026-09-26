readonly BS_ITEM_KEY_FORMAT_DEFAULT='%d'

bs::series_root() {
  local dir; dir="$(bs::data_dir)/series"
  mkdir -p "$dir"
  echo "$dir"
}

# A series' own directory: meta.json, every item file, and covers/.
bs::series_dir() {
  local dir; dir="$(bs::series_root)/$1"
  mkdir -p "$dir"
  echo "$dir"
}

bs::series_file() {
  echo "$(bs::series_dir "$1")/meta.json"
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

# Marker: series $1's matcher rules changed since its last rebuild.
bs::series_dirty_marker() {
  echo "$(bs::series_dir "$1")/.dirty"
}

bs::mark_series_dirty() {
  touch "$(bs::series_dirty_marker "$1")"
}

bs::series_is_dirty() {
  [[ -f "$(bs::series_dirty_marker "$1")" ]]
}

# Leading number of a trailing "N-M" range in $1 (e.g. "PEGASOS 3350-3399").
bs::parse_range_start() {
  grep -oE '[0-9]+-[0-9]+$' <<< "$1" | tail -1 | cut -d- -f1
}

# Sorts category ids ($1, space-separated) by bs::parse_range_start of each
# one's cached name; unparsable ones sort last, in given order.
bs::sort_categories_by_range() {
  local ids="$1" id name start
  for id in $ids; do
    name="$(jq -r '.name' "$(bs::category_file "$id")" 2> /dev/null)"
    start="$(bs::parse_range_start "$name")"
    printf '%s\t%s\n' "${start:-999999999}" "$id"
  done | sort -n -s -k1,1 | cut -f2
}

# Deduplicates a whitespace-separated list ($1), preserving order.
bs::_dedup_words() {
  tr -s ' ' '\n' <<< "$1" | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

# Comma-separated $1 -> deduped, order-preserving, space-separated list.
bs::_normalize_csv() {
  bs::_dedup_words "$(tr ',' ' ' <<< "$1")"
}

# Removes every item in $2 from $1 (both space-separated), keeping order.
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

# Writes series $1's definition file from already-finalized $2 category
# ids/$3 name/$4 item_key_format/$5 resolutions. Preserves any existing
# matchers untouched.
bs::_write_series() {
  local id="$1" ids="$2" name="$3" item_key_format="$4" resolutions="$5"
  local file; file="$(bs::series_file "$id")"
  local existing_matchers="[]"
  [[ -f "$file" ]] && existing_matchers="$(jq -c '.matchers // []' "$file")"

  local ids_json resolutions_json
  # shellcheck disable=SC2086 # word-splitting intended
  ids_json="$(printf '%s\n' $ids | jq -R . | jq -s .)"
  # shellcheck disable=SC2086
  resolutions_json="$(printf '%s\n' $resolutions | jq -R 'select(length > 0)' | jq -s .)"
  jq -n --arg id "$id" --arg name "$name" --argjson category_ids "$ids_json" \
    --arg item_key_format "$item_key_format" --argjson resolutions "$resolutions_json" \
    --argjson matchers "$existing_matchers" \
    '{series_id: $id, name: $name, category_ids: $category_ids,
      item_key_format: (if $item_key_format == "" then null else $item_key_format end),
      resolutions: $resolutions, matchers: $matchers}' \
    > "$file"
}

# Creates series $1 (overwrites if it exists). $2 categories_csv, $3
# resolutions_csv, $4 name ("" defaults to the first category's name), $5
# item_key_format, $6 order (auto|given). Starts with no matchers.
bs::series_create() {
  local id="$1" categories_csv="$2" resolutions_csv="$3" name="$4" item_key_format="$5" order="$6"
  local ids; ids="$(bs::_normalize_csv "$categories_csv")"

  if [[ "$order" == "auto" ]]; then
    ids="$(bs::sort_categories_by_range "$ids" | tr '\n' ' ')"
  fi

  if [[ -z "$name" ]]; then
    # shellcheck disable=SC2086 # word-splitting intended
    set -- $ids
    name="$(jq -r '.name' "$(bs::category_file "$1")" 2> /dev/null)"
  fi

  local resolutions; resolutions="$(bs::_normalize_csv "$resolutions_csv")"

  bs::_write_series "$id" "$ids" "$name" "$item_key_format" "$resolutions"
}

# Updates existing series $1, merging with whatever isn't given ("" means
# "leave alone" throughout).
#   $2/$3/$4  categories_csv / add_categories_csv / remove_categories_csv
#   $5/$6/$7  resolutions_csv / add_resolutions_csv / remove_resolutions_csv
#   $8 name, $9 item_key_format, $10 order
# $2 is mutually exclusive with $3/$4, and $5 with $6/$7 (validated by the
# command script, not here).
bs::series_edit() {
  local id="$1" categories_csv="$2" add_categories_csv="$3" remove_categories_csv="$4"
  local resolutions_csv="$5" add_resolutions_csv="$6" remove_resolutions_csv="$7"
  local name="$8" item_key_format="$9" order="${10}"

  local file; file="$(bs::require_series_file "$id")" || return 1
  local existing_ids existing_name existing_format existing_resolutions
  existing_ids="$(jq -r '.category_ids[]' "$file" | tr '\n' ' ')"
  existing_name="$(jq -r '.name' "$file")"
  existing_format="$(jq -r '.item_key_format // empty' "$file")"
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

  # A real item_key_format change marks the series dirty (cover display
  # names go stale until the next rebuild -- see CLAUDE.md).
  if [[ -n "$item_key_format" && "$item_key_format" != "$existing_format" ]]; then
    bs::mark_series_dirty "$id"
  else
    item_key_format="$existing_format"
  fi

  bs::_write_series "$id" "$ids" "$name" "$item_key_format" "$resolutions"
}

bs::series_item_key_format() {
  local id="$1" fmt
  fmt="$(jq -r '.item_key_format // empty' "$(bs::series_file "$id")" 2> /dev/null)"
  echo "${fmt:-$BS_ITEM_KEY_FORMAT_DEFAULT}"
}

# Fixed, zero-padded storage key for item index $1 (item-%04d) --
# unrelated to the series' own configurable item_key_format, see
# CLAUDE.md. The inverse (key -> index) is matched inline as
# `^item-([0-9]+)$` at every hot-path call site rather than through a
# shared helper, to stay subprocess-free in per-item loops.
bs::_item_storage_key() {
  printf 'item-%04d' "$1"
}

# Prints series $1's matchers as one compact JSON object per line:
# {index, pattern, categories} -- index is the current array position,
# computed fresh every call, never stored.
bs::series_matchers() {
  local id="$1"
  jq -c '(.matchers // []) | to_entries[] | {index: .key, pattern: .value.pattern, categories: (.value.categories // [])}' \
    "$(bs::series_file "$id")" 2> /dev/null
}

# Appends a new matcher {pattern, categories} to series $1's matchers
# array. $3 categories_csv may be empty (applies regardless of category).
bs::add_series_matcher() {
  local id="$1" pattern="$2" categories_csv="$3" file
  file="$(bs::require_series_file "$id")" || return 1

  local categories_json="[]"
  if [[ -n "$categories_csv" ]]; then
    categories_json="$(tr ',' '\n' <<< "$categories_csv" | jq -R 'select(length > 0)' | jq -s .)"
  fi

  local content
  content="$(jq --arg pattern "$pattern" --argjson categories "$categories_json" \
    '.matchers = ((.matchers // []) + [{pattern: $pattern, categories: $categories}])' \
    "$file")" && bs::write_file "$file" "$content" && bs::mark_series_dirty "$id"
}

# Removes the matcher at $2 (0-based array index) from series $1.
bs::remove_series_matcher_at() {
  local id="$1" index="$2" file
  file="$(bs::require_series_file "$id")" || return 1

  local count; count="$(jq '(.matchers // []) | length' "$file")"
  if [[ "$index" -lt 0 || "$index" -ge "$count" ]]; then
    echo "error: series '$id' has no matcher at index $index (has $count, valid range 0..$((count - 1)))" >&2
    return 1
  fi

  local content
  content="$(jq --argjson i "$index" 'del(.matchers[$i])' "$file")" && bs::write_file "$file" "$content" && bs::mark_series_dirty "$id"
}

# Updates the matcher at $2 (0-based index) in place. $3 pattern ("" ==
# leave alone), $4 categories_csv (full replacement) mutually exclusive
# with $5/$6 add/remove (merged into the current category list).
bs::edit_series_matcher_at() {
  local id="$1" index="$2" pattern="$3" categories_csv="$4" add_categories_csv="$5" remove_categories_csv="$6"
  local file; file="$(bs::require_series_file "$id")" || return 1

  local count; count="$(jq '(.matchers // []) | length' "$file")"
  if [[ "$index" -lt 0 || "$index" -ge "$count" ]]; then
    echo "error: series '$id' has no matcher at index $index (has $count, valid range 0..$((count - 1)))" >&2
    return 1
  fi

  local ids
  if [[ -n "$categories_csv" ]]; then
    ids="$(bs::_normalize_csv "$categories_csv")"
  else
    local existing_categories
    existing_categories="$(jq -r --argjson i "$index" '(.matchers[$i].categories // [])[]' "$file" | tr '\n' ' ')"
    ids="$existing_categories"
    [[ -n "$add_categories_csv" ]] && ids="$ids $(tr ',' ' ' <<< "$add_categories_csv")"
    [[ -n "$remove_categories_csv" ]] && ids="$(bs::_subtract_list "$ids" "$(tr ',' ' ' <<< "$remove_categories_csv")")"
    ids="$(bs::_dedup_words "$ids")"
  fi

  local categories_json
  # shellcheck disable=SC2086 # word-splitting intended
  categories_json="$(printf '%s\n' $ids | jq -R 'select(length > 0)' | jq -s .)"

  local content
  content="$(jq --argjson i "$index" --argjson categories "$categories_json" \
    '.matchers[$i].categories = $categories' "$file")" || return 1
  if [[ -n "$pattern" ]]; then
    content="$(jq --argjson i "$index" --arg pattern "$pattern" '.matchers[$i].pattern = $pattern' <<< "$content")" || return 1
  fi

  bs::write_file "$file" "$content" && bs::mark_series_dirty "$id"
}

# Reorders series $1's matchers: indices in $2.. move to the front, in
# the order given; everything else follows, in its current relative
# order. Validates every index is in range and not repeated first.
bs::reorder_series_matchers() {
  local id="$1"; shift
  local front=("$@")
  local file; file="$(bs::require_series_file "$id")" || return 1

  local count; count="$(jq '(.matchers // []) | length' "$file")"

  local -A seen=()
  local i
  for i in "${front[@]}"; do
    if [[ "$i" -lt 0 || "$i" -ge "$count" ]]; then
      echo "error: series '$id' has no matcher at index $i (has $count, valid range 0..$((count - 1)))" >&2
      return 1
    fi
    if [[ -n "${seen[$i]:-}" ]]; then
      echo "error: index $i given more than once" >&2
      return 1
    fi
    seen["$i"]=1
  done

  local order=("${front[@]}")
  for (( i = 0; i < count; i++ )); do
    [[ -n "${seen[$i]:-}" ]] || order+=("$i")
  done

  local order_json; order_json="$(printf '%s\n' "${order[@]}" | jq -s '[.[] | tonumber]')"

  # `.matchers as $m` captures the array before reassigning -- inside
  # map(), `.` is each $order element, so `.matchers[.]` alone (without
  # $m) would look for a `matchers` field on a bare number, not the
  # original array.
  local content
  content="$(jq --argjson order "$order_json" '.matchers as $m | .matchers = ($order | map($m[.]))' "$file")" \
    && bs::write_file "$file" "$content" && bs::mark_series_dirty "$id"
}

# Prints series $1's matchers as a table, or a "none yet" hint.
bs::print_series_matchers_table() {
  local id="$1"
  local lines; lines="$(bs::series_matchers "$id")"
  if [[ -z "$lines" ]]; then
    echo "No matchers defined yet for series '$id'. Run 'series matcher add' to add one."
    return 0
  fi

  {
    printf 'index\tpattern\tcategories\n'
    jq -r '[.index, .pattern, ((.categories // []) | join(","))] | @tsv' <<< "$lines"
  } | column -t -s $'\t' -R 1
}

# Title-cleanup hook, currently an identity stub. $1 series meta file, $2
# pre-cleanup title. See CLAUDE.md's "Open design questions".
bs::clean_series_item_title() {
  # shellcheck disable=SC2034 # placeholder for a future cleanup rule
  local series_meta_file="$1" title="$2"
  echo "$title"
}

# Pre-parses series $1's matchers into rows (index\x01pattern\x01
# categories_csv) for a caller about to call bs::_resolve_series_match
# many times over -- pass the result in as its own $5 rather than have it
# re-derive this from meta.json on every call.
bs::_matcher_rows() {
  local series_id="$1" mline m_index m_pattern m_categories
  while IFS= read -r mline; do
    [[ -n "$mline" ]] || continue
    m_index="$(jq -r '.index' <<< "$mline")"
    m_pattern="$(jq -r '.pattern' <<< "$mline")"
    m_categories="$(jq -r '(.categories // []) | join(",")' <<< "$mline")"
    printf '%s\x01%s\x01%s\n' "$m_index" "$m_pattern" "$m_categories"
  done < <(bs::series_matchers "$series_id")
}

# Resolves whether/how product $1 (full comma-joined category set $2,
# title $3) belongs in series $4 -- pure, no writes. $5 is
# bs::_matcher_rows' own output for this series. Prints
# key\x01cleaned_title, or nothing if it doesn't belong (excluded via
# override, or no matcher matched).
bs::_resolve_series_match() {
  local product_id="$1" category_ids="$2" title="$3" series_id="$4" matcher_rows="$5"
  local product_file; product_file="$(bs::product_file "$product_id")"

  local item_index="" pre_title="" override_item=""

  local override; override="$(jq -c --arg sid "$series_id" '.overrides[$sid] // empty' "$product_file" 2> /dev/null)"
  if [[ -n "$override" && "$override" != "null" ]]; then
    if [[ "$(jq -r '.exclude // false' <<< "$override")" == "true" ]]; then
      return 0
    fi
    override_item="$(jq -r '.item // empty' <<< "$override")"
    if [[ -n "$override_item" ]]; then
      item_index="$override_item"
      pre_title="$title"
    fi
    # malformed/empty override (neither exclude nor item): falls through
    # to matcher evaluation below, same as no override.
  fi

  if [[ -z "$override" || "$override" == "null" || -z "$override_item" ]]; then
    local matched=0
    local m_index m_pattern m_categories
    while IFS=$'\x01' read -r m_index m_pattern m_categories; do
      [[ -n "$m_pattern" ]] || continue

      if [[ -n "$m_categories" ]]; then
        local in_scope="" c pc cats pcats
        IFS=',' read -r -a cats <<< "$m_categories"
        IFS=',' read -r -a pcats <<< "$category_ids"
        for c in "${cats[@]}"; do
          for pc in "${pcats[@]}"; do
            [[ -n "$c" && "$c" == "$pc" ]] && { in_scope=1; break 2; }
          done
        done
        [[ -n "$in_scope" ]] || continue
      fi

      local cap_result
      cap_result="$(jq -n --arg title "$title" --arg re "$m_pattern" \
        '$title | if test($re) then (capture($re) // {}) else null end' 2> /dev/null)"
      [[ -n "$cap_result" && "$cap_result" != "null" ]] || continue

      matched=1
      local raw_index raw_title
      raw_index="$(jq -r '.index // empty' <<< "$cap_result")"
      raw_title="$(jq -r '.title // empty' <<< "$cap_result")"
      if [[ -n "$raw_index" ]]; then
        if [[ "$raw_index" =~ ^[0-9]+$ ]]; then
          item_index="$raw_index"
        else
          echo "warning: series $series_id matcher $m_index captured a non-numeric <index> (\"$raw_index\") for \"$title\" -- treating this item as unkeyed" >&2
        fi
      fi
      [[ -n "$raw_title" ]] && pre_title="$raw_title"
      break
    done <<< "$matcher_rows"

    [[ "$matched" -eq 1 ]] || return 0
  fi

  [[ -n "$pre_title" ]] || pre_title="$title"
  local cleaned_title; cleaned_title="$(bs::clean_series_item_title "$(bs::series_file "$series_id")" "$pre_title")"

  local key
  if [[ -n "$item_index" ]]; then
    key="$(bs::_item_storage_key "$item_index")"
  else
    # ".product-<id>", namespaced so it can't collide with any other
    # dot-prefixed marker (e.g. ".dirty").
    key=".product-${product_id}"
  fi

  # \x01, not a tab: bash's `read` collapses consecutive tabs regardless
  # of IFS, silently eating an empty field -- see CLAUDE.md. Every
  # @tsv/read pair in this project that can carry a non-trailing empty
  # field uses \x01 instead.
  printf '%s\x01%s\n' "$key" "$cleaned_title"
}

# Ensures series $1's item $2 (its fixed storage key) has a correct
# covers/original/<display-key>.<ext> symlink. Idempotent/self-correcting
# -- safe to call any time the item's own file might have changed.
# Effective image key: manual.image_key // derived.product_id. $3
# item_key_format is optional -- a caller in a per-item loop should pass
# its own already-hoisted value; a one-off caller leaves it empty and
# gets it fetched fresh.
bs::_link_series_item() {
  local series_id="$1" key="$2" item_key_format="${3:-}"
  local series_dir; series_dir="$(bs::series_dir "$series_id")"
  local orig_dir="${series_dir}/covers/original"
  mkdir -p "$orig_dir"

  local display_key="$key"
  if [[ "$key" =~ ^item-([0-9]+)$ ]]; then
    local index=$((10#${BASH_REMATCH[1]}))
    local fmt="$item_key_format"
    [[ -n "$fmt" ]] || fmt="$(bs::series_item_key_format "$series_id")"
    # shellcheck disable=SC2059 # item_key_format is a trusted pattern, not user input
    printf -v display_key "$fmt" "$index"
  fi

  local old
  shopt -s nullglob
  for old in "${orig_dir}/${display_key}".*; do
    rm -f "$old"
  done
  shopt -u nullglob

  local target="${series_dir}/${key}.json"
  [[ -f "$target" ]] || return 0

  local image_key; image_key="$(jq -r '(.manual.image_key // .derived.product_id) // empty' "$target")"
  [[ -n "$image_key" ]] || return 0

  local image_file; image_file="$(bs::image_file "$image_key")" || return 0
  local base; base="${image_file##*/}"
  local ext="${base##*.}"
  ln -sf "../../../../images/${base}" "${orig_dir}/${display_key}.${ext}"
}

# Recomputes series $1's item $2's `derived` field from its current
# `matched.product_ids`/`manual.product_id`: manual pick wins if set
# (even absent from matched), else the sole matched entry, else null.
# `derived.title` is the winner's raw title re-run through this series'
# own matchers to pick up a cleaned <title> capture, falling back to the
# raw title if it doesn't actually match anything.
#
# $3 matcher_rows, $4 category_map_name (name of a caller-local
# product_id -> category_ids associative array, bound via `local -n`),
# $5 item_key_format (forwarded to bs::_link_series_item), $6
# products_dir_hint (plain string interpolation instead of
# bs::product_file) are all OPTIONAL -- only bs::rebuild_series' own
# per-item loop passes them; a one-off caller leaves them empty and gets
# the same correct result, just re-derived fresh.
#
# Deletes the file outright if matched AND manual both end up empty.
# Otherwise always finishes with bs::_link_series_item. Call this after
# ANY change to a key's matched.product_ids or manual.product_id.
bs::_recompute_item() {
  local series_id="$1" key="$2" matcher_rows="${3:-}" category_map_name="${4:-}" item_key_format="${5:-}" products_dir_hint="${6:-}"
  local series_dir; series_dir="$(bs::series_dir "$series_id")"
  local target="${series_dir}/${key}.json"
  [[ -f "$target" ]] || return 0

  local manual_json; manual_json="$(jq -c '.manual // {}' "$target")"
  local manual_pid; manual_pid="$(jq -r '.product_id // empty' <<< "$manual_json")"
  local matched_json; matched_json="$(jq -c '.matched.product_ids // []' "$target")"
  local matched_count; matched_count="$(jq 'length' <<< "$matched_json")"

  if [[ "$matched_count" -eq 0 && "$manual_json" == "{}" ]]; then
    rm -f "$target"
    bs::_link_series_item "$series_id" "$key" "$item_key_format"
    return 0
  fi

  local winner=""
  if [[ -n "$manual_pid" ]]; then
    winner="$manual_pid"
  elif [[ "$matched_count" -eq 1 ]]; then
    winner="$(jq -r '.[0]' <<< "$matched_json")"
  fi

  local derived_json="null"
  if [[ -n "$winner" ]]; then
    local pfile
    if [[ -n "$products_dir_hint" ]]; then
      pfile="${products_dir_hint}/${winner}.json"
    else
      pfile="$(bs::product_file "$winner")"
    fi
    if [[ -f "$pfile" ]]; then
      local wtitle; wtitle="$(jq -r '.title // empty' "$pfile")"

      local wcategory_ids=""
      if [[ -n "$category_map_name" ]]; then
        local -n _bs_recompute_category_map="$category_map_name"
        wcategory_ids="${_bs_recompute_category_map[$winner]:-}"
      else
        wcategory_ids="$(bs::categories_for_product "$winner" | paste -sd, -)"
      fi

      local rows="$matcher_rows"
      [[ -n "$rows" ]] || rows="$(bs::_matcher_rows "$series_id")"

      local resolved derived_title="$wtitle"
      resolved="$(bs::_resolve_series_match "$winner" "$wcategory_ids" "$wtitle" "$series_id" "$rows")"
      [[ -n "$resolved" ]] && derived_title="${resolved#*$'\x01'}"
      derived_json="$(jq -n --arg pid "$winner" --arg title "$derived_title" '{product_id: $pid, title: $title}')"
    fi
  fi

  local content
  content="$(jq --argjson derived "$derived_json" '.derived = $derived' "$target")" && bs::write_file "$target" "$content"
  bs::_link_series_item "$series_id" "$key" "$item_key_format"
}

# Removes product $3 from series $1's item $2's matched.product_ids (a
# no-op if absent), then recomputes that item.
bs::_remove_matched_product() {
  local series_id="$1" key="$2" product_id="$3"
  local series_dir; series_dir="$(bs::series_dir "$series_id")"
  local target="${series_dir}/${key}.json"
  [[ -f "$target" ]] || return 0

  local content
  content="$(jq --arg pid "$product_id" '.matched.product_ids = ((.matched.product_ids // []) - [$pid])' "$target")" \
    && bs::write_file "$target" "$content"
  bs::_recompute_item "$series_id" "$key"
}

# Records that product $1 (category_ids $2, title $3) currently matches
# series $4's resolved key -- appends to that key's matched.product_ids
# (creating the item file if needed) and recomputes derived. Does nothing
# if $1 doesn't resolve into series $4. $6/$7/$8 (category_map_name/
# item_key_format/products_dir_hint), if given, are just forwarded to
# bs::_recompute_item.
bs::_classify_product_into_series() {
  local product_id="$1" category_ids="$2" title="$3" series_id="$4" matcher_rows="$5" category_map_name="${6:-}" item_key_format="${7:-}" products_dir_hint="${8:-}"

  local resolved; resolved="$(bs::_resolve_series_match "$product_id" "$category_ids" "$title" "$series_id" "$matcher_rows")"
  [[ -n "$resolved" ]] || return 0

  local key="${resolved%%$'\x01'*}"

  local series_dir; series_dir="$(bs::series_dir "$series_id")"
  local target="${series_dir}/${key}.json"

  if [[ ! -f "$target" ]]; then
    local skeleton
    skeleton="$(jq -n '{matched: {product_ids: []}, derived: null, manual: {}}')" \
      && bs::write_file "$target" "$skeleton"
  fi

  local content
  content="$(jq --arg pid "$product_id" \
    '.matched.product_ids = ((.matched.product_ids // []) + [$pid] | unique)' \
    "$target")" && bs::write_file "$target" "$content"

  bs::_recompute_item "$series_id" "$key" "$matcher_rows" "$category_map_name" "$item_key_format" "$products_dir_hint"
}

# Classifies product $1 (title $2) against every defined series (global
# matching). Looks up $1's own full category set itself. Call once per
# product, right after its image and product record are both in place.
bs::classify_product() {
  local product_id="$1" title="$2"
  local category_ids; category_ids="$(bs::categories_for_product "$product_id" | paste -sd, -)"
  local series_id
  while IFS= read -r series_id; do
    [[ -n "$series_id" ]] || continue
    local matcher_rows; matcher_rows="$(bs::_matcher_rows "$series_id")"
    bs::_classify_product_into_series "$product_id" "$category_ids" "$title" "$series_id" "$matcher_rows"
  done < <(bs::all_series_ids)
}

# Rebuilds series $1's classification against every cached product, with
# no network access. $2 quiet suppresses the status line. See CLAUDE.md's
# "series rebuild" section for the full two-pass algorithm (revalidate
# every existing item in place, then discover new matches by walking the
# product cache, skipping anything pass 1 already confirmed settled).
bs::rebuild_series() {
  local series_id="$1" quiet="$2"
  bs::require_series_file "$series_id" > /dev/null || return 1
  local series_dir; series_dir="$(bs::series_dir "$series_id")"

  local matcher_rows; matcher_rows="$(bs::_matcher_rows "$series_id")"
  local item_key_format; item_key_format="$(bs::series_item_key_format "$series_id")"

  # Every product's full linked-category set, one pass per category dir.
  local -A category_ids_for=()
  local ac_pid ac_cid
  while IFS=$'\x01' read -r ac_pid ac_cid; do
    [[ -n "$ac_pid" ]] || continue
    if [[ -n "${category_ids_for[$ac_pid]:-}" ]]; then
      category_ids_for["$ac_pid"]+=",${ac_cid}"
    else
      category_ids_for["$ac_pid"]="$ac_cid"
    fi
  done < <(bs::_all_categories_for_products)

  # Products pass 1 confirms are still correctly placed -- pass 2 skips these.
  local -A settled_products=()

  local products_dir; products_dir="$(bs::products_dir)"

  local candidates=() f
  shopt -s nullglob dotglob
  for f in "$series_dir"/*.json; do
    [[ "${f##*/}" == meta.json ]] && continue
    candidates+=("$f")
  done
  shopt -u nullglob dotglob

  local total_items="${#candidates[@]}" done_items=0
  local key pid pfile ptitle pcats resolved new_key keep_list matched_json content
  for f in "${candidates[@]}"; do
    done_items=$((done_items + 1))
    bs::status_line "series $series_id: validating [$done_items/$total_items]..." "$quiet"
    key="${f##*/}"
    key="${key%.json}"

    keep_list=()
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue

      pfile="${products_dir}/${pid}.json"
      ptitle=""
      [[ -f "$pfile" ]] && ptitle="$(jq -r '.title // empty' "$pfile")"
      [[ -n "$ptitle" ]] || continue

      pcats="${category_ids_for[$pid]:-}"
      resolved="$(bs::_resolve_series_match "$pid" "$pcats" "$ptitle" "$series_id" "$matcher_rows")"
      [[ -n "$resolved" ]] || continue
      new_key="${resolved%%$'\x01'*}"
      [[ "$new_key" == "$key" ]] || continue

      keep_list+=("$pid")
      settled_products["$pid"]=1
    done < <(jq -r '(.matched.product_ids // [])[]' "$f")

    matched_json="$(printf '%s\n' "${keep_list[@]}" | jq -R 'select(length > 0)' | jq -s .)"
    content="$(jq --argjson matched "$matched_json" '.matched.product_ids = $matched' "$f")" && bs::write_file "$f" "$content"

    bs::_recompute_item "$series_id" "$key" "$matcher_rows" "category_ids_for" "$item_key_format" "$products_dir"
  done

  shopt -s nullglob
  local all_products=("$products_dir"/*.json)
  shopt -u nullglob
  local total="${#all_products[@]}" processed=0

  local pfile2 product_id title category_ids
  for pfile2 in "${all_products[@]}"; do
    processed=$((processed + 1))
    product_id="${pfile2##*/}"
    product_id="${product_id%.json}"
    bs::status_line "series $series_id: rebuilding [$processed/$total] $product_id..." "$quiet"
    [[ -n "${settled_products[$product_id]:-}" ]] && continue

    title="$(jq -r '.title // empty' "$pfile2")"
    [[ -n "$title" ]] || continue

    category_ids="${category_ids_for[$product_id]:-}"
    bs::_classify_product_into_series "$product_id" "$category_ids" "$title" "$series_id" "$matcher_rows" "category_ids_for" "$item_key_format" "$products_dir"
  done

  rm -f "$(bs::series_dirty_marker "$series_id")"

  bs::status_line_clear "$quiet"
}

# Finds the key product $2 currently matches in series $1, if any --
# prints its key (no ".json"), returns 1 if not currently matched there.
bs::_find_current_key() {
  local series_id="$1" product_id="$2" series_dir
  series_dir="$(bs::series_dir "$series_id")"
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if jq -e --arg pid "$product_id" '(.matched.product_ids // []) | any(. == $pid)' "$f" > /dev/null 2>&1; then
      basename "$f" .json
      return 0
    fi
  done < <(grep -rlF "\"$product_id\"" "$series_dir" 2> /dev/null)
  return 1
}

# Applies an already-written override change for product $1 in series $2
# immediately: reclassifies it into whatever it now resolves to (if
# anything), and cleans up its old key if that changed.
bs::apply_product_override() {
  local product_id="$1" series_id="$2"
  local product_file; product_file="$(bs::product_file "$product_id")"
  [[ -f "$product_file" ]] || return 0

  local title; title="$(jq -r '.title // empty' "$product_file")"
  [[ -n "$title" ]] || return 0

  local category_ids; category_ids="$(bs::categories_for_product "$product_id" | paste -sd, -)"
  local old_key; old_key="$(bs::_find_current_key "$series_id" "$product_id")" || old_key=""

  local matcher_rows; matcher_rows="$(bs::_matcher_rows "$series_id")"
  local resolved new_key=""
  resolved="$(bs::_resolve_series_match "$product_id" "$category_ids" "$title" "$series_id" "$matcher_rows")"
  [[ -n "$resolved" ]] && new_key="${resolved%%$'\x01'*}"

  if [[ -n "$old_key" && "$old_key" != "$new_key" ]]; then
    bs::_remove_matched_product "$series_id" "$old_key" "$product_id"
  fi

  [[ -n "$resolved" ]] && bs::_classify_product_into_series "$product_id" "$category_ids" "$title" "$series_id" "$matcher_rows"
  # Explicit: the "&&" chain above legitimately evaluates to 1 when
  # $resolved is empty (a no-op, not a failure) -- without this, `set -e`
  # would abort the caller before its own confirmation message.
  return 0
}

# Fully-manual cover import for series $1's item $2 -- no backing shop
# product involved. Copies $3 into images/ as a synthetic
# import-<timestamp>-<pid> key, then merge-writes manual.title/
# manual.image_key onto the resolved series-item. $4 title is required.
# Refuses to overwrite an existing genuine cover unless $5 force. Always
# reports "final".
bs::import_manual_cover() {
  local series_id="$1" item_number="$2" src_file="$3" title="$4" force="$5" quiet="$6"
  bs::require_series_file "$series_id" > /dev/null || return 1
  [[ -f "$src_file" ]] || { echo "error: no such file: $src_file" >&2; return 1; }

  local key; key="$(bs::_item_storage_key "$item_number")"

  local series_dir; series_dir="$(bs::series_dir "$series_id")"
  local target="${series_dir}/${key}.json"

  if [[ -f "$target" && -z "$force" ]]; then
    local existing_image_key; existing_image_key="$(jq -r '.manual.image_key // .derived.product_id // empty' "$target")"
    if [[ -n "$existing_image_key" ]] && bs::image_file "$existing_image_key" > /dev/null 2>&1; then
      echo "error: series $series_id item $key already has a real cover -- pass --force to overwrite" >&2
      return 1
    fi
  fi

  local ext="${src_file##*.}"
  [[ "$ext" =~ ^[A-Za-z0-9]{2,4}$ ]] || ext="jpg"
  local image_key; image_key="import-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local images_dir; images_dir="$(bs::images_dir)"
  local dest="${images_dir}/${image_key}.${ext}"
  # `cat > dest`, not `cp` -- see beam_shop_covers.sh's bs::import_cover.
  cat -- "$src_file" > "$dest"

  local hash; hash="$(sha256sum "$dest" | cut -d' ' -f1)"
  bs::register_image_hash "$hash" "$image_key"

  local existing_manual="{}" existing_matched="[]"
  if [[ -f "$target" ]]; then
    existing_manual="$(jq -c '.manual // {}' "$target")"
    existing_matched="$(jq -c '.matched.product_ids // []' "$target")"
  fi

  local content
  content="$(jq -n --arg title "$title" --arg image_key "$image_key" \
    --argjson manual "$existing_manual" --argjson matched "$existing_matched" \
    '{
      matched: {product_ids: $matched},
      derived: null,
      manual: ($manual + {title: $title, image_key: $image_key})
    }')" && bs::write_file "$target" "$content"

  bs::_recompute_item "$series_id" "$key"

  echo "final"
}

# Prints series $1's own resize resolution specs, one per line (empty if
# none -- bs::resize_series then falls back to config keys).
bs::series_resolutions() {
  local id="$1"
  jq -r '(.resolutions // [])[]' "$(bs::series_file "$id")" 2> /dev/null
}

# Validates $1, a comma-separated list of resize geometry specs -- only
# checks for whitespace (a spec is passed straight through to
# ImageMagick's -resize, so its full grammar isn't policed here). Prints
# the bad entry and returns 1 on failure.
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

# Prints every defined series' own id, one per line -- a subdirectory of
# series/ counts only if it has its own meta.json.
bs::all_series_ids() {
  local d
  for d in "$(bs::series_root)"/*/; do
    [[ -f "${d}meta.json" ]] || continue
    basename "$d"
  done
}

# Prints series $1's own member category ids, one per line.
bs::series_category_ids() {
  local id="$1" file
  file="$(bs::require_series_file "$id")" || return 1
  jq -r '.category_ids[]' "$file"
}

# Finds the already-classified product at series $1's item number $2, if
# any -- prints {product_id, title}; returns 1 if no such record, or it's
# fully-manual with no backing product. Direct single-file lookup by the
# fixed storage key.
bs::find_series_item() {
  local series_id="$1" item_number="$2"
  bs::require_series_file "$series_id" > /dev/null || return 1

  local key; key="$(bs::_item_storage_key "$item_number")"

  local series_dir; series_dir="$(bs::series_dir "$series_id")"
  local target="${series_dir}/${key}.json"
  [[ -f "$target" ]] || return 1

  local pid; pid="$(jq -r '.derived.product_id // empty' "$target")"
  [[ -n "$pid" ]] || return 1

  jq -c '{product_id: .derived.product_id, title: (.manual.title // .derived.title)}' "$target"
}

# Removes series $1's own definition and everything derived from it
# (meta.json, every item file, covers/) in one shot. Never touches
# canonical products/images data.
bs::series_remove() {
  local id="$1"
  local file; file="$(bs::series_file "$id")"
  [[ -f "$file" ]] || { echo "$id -> not found" >&2; return 1; }

  rm -rf "$(bs::series_dir "$id")"
}

# Rebuilds series $1's covers/ subtree (images only) from its
# already-classified series-item files -- deletes and recreates covers/
# entirely, but leaves every *.json file untouched. $2 quiet suppresses
# the status line.
bs::series_relink() {
  local id="$1" quiet="$2" file
  file="$(bs::require_series_file "$id")" || return 1

  local series_dir; series_dir="$(bs::series_dir "$id")"
  local orig_dir="${series_dir}/covers/original"
  rm -rf "${series_dir}/covers"
  mkdir -p "$orig_dir"

  local item_key_format; item_key_format="$(bs::series_item_key_format "$id")"

  local candidates=() f
  shopt -s nullglob dotglob
  for f in "$series_dir"/*.json; do
    [[ "$(basename "$f")" == meta.json ]] && continue
    candidates+=("$f")
  done
  shopt -u nullglob dotglob
  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo 0
    return 0
  fi

  local images_dir; images_dir="$(bs::images_dir)"
  local -A image_for=()
  local base
  shopt -s nullglob
  for f in "$images_dir"/*; do
    base="${f##*/}"
    image_for["${base%.*}"]="$base"
  done
  shopt -u nullglob

  local rows; rows="$(jq -r \
    '[input_filename, (.manual.image_key // .derived.product_id // empty)] | join("\u0001")' \
    "${candidates[@]}")"

  local linked=0 processed=0
  local item_path image_key key display_key index image_file ext
  while IFS=$'\x01' read -r item_path image_key; do
    [[ -n "$item_path" ]] || continue
    processed=$((processed + 1))
    key="$(basename "$item_path" .json)"
    bs::status_line "series $id: relinking [$processed] $key..." "$quiet"

    [[ -n "$image_key" ]] || continue
    image_file="${image_for[$image_key]:-}"
    [[ -n "$image_file" ]] || continue
    ext="${image_file##*.}"

    display_key="$key"
    if [[ "$key" =~ ^item-([0-9]+)$ ]]; then
      index=$((10#${BASH_REMATCH[1]}))
      # shellcheck disable=SC2059 # item_key_format is a trusted pattern, not user input
      printf -v display_key "$item_key_format" "$index"
    fi

    ln -s "../../../../images/${image_file}" "${orig_dir}/${display_key}.${ext}"
    linked=$((linked + 1))
  done <<< "$rows"

  bs::status_line_clear "$quiet"
  echo "$linked"
}

# Reports problems in series $1's cached data, purely from local
# metadata (no network access). Emits one JSON object per finding
# ({item_number, kind, product_id, title}), unsorted. Kinds: missing,
# broken, placeholder, unsorted, ambiguous, promoted -- see CLAUDE.md's
# "series audit" section for what each means. $2 hide_promoted suppresses
# the "promoted" kind.
bs::series_audit() {
  local id="$1" hide_promoted="$2"
  bs::require_series_file "$id" > /dev/null || return 1
  local series_dir; series_dir="$(bs::series_dir "$id")"

  local item_files=() f
  shopt -s nullglob dotglob
  for f in "$series_dir"/*.json; do
    [[ "$(basename "$f")" == meta.json ]] && continue
    item_files+=("$f")
  done
  shopt -u nullglob dotglob

  local images_dir; images_dir="$(bs::images_dir)"
  local -A has_image=()
  local base
  shopt -s nullglob
  for f in "$images_dir"/*; do
    base="$(basename "$f")"
    has_image["${base%.*}"]=1
  done
  shopt -u nullglob

  local products_dir; products_dir="$(bs::products_dir)"
  shopt -s nullglob
  local all_products=("$products_dir"/*.json)
  shopt -u nullglob
  local -A cover_status_for=() failure_reason_for=()
  if [[ "${#all_products[@]}" -gt 0 ]]; then
    local pid status reason
    while IFS=$'\x01' read -r pid status reason; do
      [[ -n "$pid" ]] || continue
      cover_status_for["$pid"]="$status"
      failure_reason_for["$pid"]="$reason"
    done < <(jq -r '[.product_id, .cover_status, (.failure_reason // "")] | join("\u0001")' "${all_products[@]}")
  fi

  local out=""
  local -A seen=()
  local min="" max=""

  if [[ "${#item_files[@]}" -gt 0 ]]; then
    local rows; rows="$(jq -r \
      '[input_filename, (.derived.product_id // ""), ((.manual.image_key // .derived.product_id) // ""),
        ((.manual.title // .derived.title) // ""),
        ((.matched.product_ids // []) | join(",")), (.manual.product_id // "")] | join("\u0001")' \
      "${item_files[@]}")"

    local item_path derived_pid image_key title matched_csv manual_pid
    local key item_index display_title is_broken is_placeholder status reason
    while IFS=$'\x01' read -r item_path derived_pid image_key title matched_csv manual_pid; do
      [[ -n "$item_path" ]] || continue
      key="$(basename "$item_path" .json)"

      if [[ "$key" == .* ]]; then
        out+="-1"$'\t'"unsorted"$'\t'"${image_key}"$'\t'"${title}"$'\n'
        continue
      fi

      if [[ "$key" =~ ^item-([0-9]+)$ ]]; then
        item_index=$((10#${BASH_REMATCH[1]}))
      else
        item_index=-1
      fi

      if [[ "$item_index" != "-1" ]]; then
        seen["$item_index"]=1
        [[ -z "$min" || "$item_index" -lt "$min" ]] && min="$item_index"
        [[ -z "$max" || "$item_index" -gt "$max" ]] && max="$item_index"
      fi

      display_title="$title"; is_broken=""; is_placeholder=""
      if [[ -z "$image_key" || -z "${has_image[$image_key]:-}" ]]; then
        is_broken=1
      elif [[ -n "$derived_pid" ]]; then
        status="${cover_status_for[$derived_pid]:-}"
        if [[ "$status" == "failed" ]]; then
          is_broken=1
          reason="${failure_reason_for[$derived_pid]:-}"
          [[ -n "$reason" ]] && display_title="$title (reason: $reason)"
        elif [[ "$status" == "placeholder" ]]; then
          is_placeholder=1
        fi
      fi

      if [[ -n "$is_broken" ]]; then
        out+="${item_index}"$'\t'"broken"$'\t'"${image_key}"$'\t'"${display_title}"$'\n'
      elif [[ -n "$is_placeholder" ]]; then
        out+="${item_index}"$'\t'"placeholder"$'\t'"${image_key}"$'\t'"${title}"$'\n'
      fi

      if [[ "$matched_csv" == *,* && -z "$manual_pid" ]]; then
        out+="${item_index}"$'\t'"ambiguous"$'\t'"${matched_csv}"$'\t'""$'\n'
      fi

      if [[ -z "$hide_promoted" && -n "$manual_pid" ]]; then
        local in_matched="" mp
        IFS=',' read -r -a matched_arr <<< "$matched_csv"
        for mp in "${matched_arr[@]}"; do [[ -n "$mp" && "$mp" == "$manual_pid" ]] && in_matched=1; done
        [[ -n "$in_matched" ]] || out+="${item_index}"$'\t'"promoted"$'\t'"${manual_pid}"$'\t'""$'\n'
      fi
    done <<< "$rows"
  fi

  if [[ -n "$min" ]]; then
    local n
    for (( n = min; n <= max; n++ )); do
      [[ -n "${seen[$n]:-}" ]] || out+="${n}"$'\t'"missing"$'\t'""$'\t'""$'\n'
    done
  fi

  [[ -n "$out" ]] || return 0

  jq -R -c 'split("\t") | {
    item_number: (if .[0] == "-1" then null else (.[0] | tonumber) end),
    kind: .[1],
    product_id: (if .[2] == "" then null else .[2] end),
    title: (if .[3] == "" then null else .[3] end)
  }' <<< "${out%$'\n'}"
}
