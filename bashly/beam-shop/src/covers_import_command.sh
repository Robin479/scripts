: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
image_file="${args[image_file]}"
product_id="${args[--product]:-}"
category_id="${args[--category]:-}"
title="${args[--title]:-}"
series_id="${args[--series]:-}"
item_number="${args[--item]:-}"
force="${args[--force]:-}"
# No --batch flag on this command -- just the automatic terminal check
# (see bs::fetch_quiet); must be a plain if, not a command substitution.
quiet=""
if bs::fetch_quiet ""; then
  quiet=1
fi

manual_given=0
[[ -n "$product_id" || -n "$category_id" || -n "$title" ]] && manual_given=1
lookup_given=0
[[ -n "$series_id" || -n "$item_number" ]] && lookup_given=1

if [[ "$manual_given" -eq 1 && "$lookup_given" -eq 1 ]]; then
  echo "error: give either --product/--category/--title, or --series/--item, not both" >&2
  exit 1
fi

if [[ "$lookup_given" -eq 1 ]]; then
  if [[ -z "$series_id" || -z "$item_number" ]]; then
    echo "error: --series and --item must be given together" >&2
    exit 1
  fi
  if [[ ! "$item_number" =~ ^[0-9]+$ ]]; then
    echo "error: --item must be a positive integer" >&2
    exit 1
  fi

  found="$(bs::find_series_item "$series_id" "$item_number")" || {
    echo "error: no existing record for series '$series_id' item $item_number -- it was never successfully fetched, so its shop product id can't be resolved this way. Find it manually (its own product URL on the shop, or an earlier 'covers fetch' error naming it) and use --product/--category/--title instead." >&2
    exit 1
  }
  product_id="$(jq -r '.product_id' <<< "$found")"
  category_id="$(jq -r '.category_id' <<< "$found")"
  title="$(jq -r '.title' <<< "$found")"
elif [[ -z "$product_id" || -z "$category_id" || -z "$title" ]]; then
  echo "error: give --product, --category, and --title together, or --series and --item" >&2
  exit 1
fi

status="$(bs::import_cover "$category_id" "$product_id" "$image_file" "$title" "$force" "$quiet")" || exit 1
echo "$product_id -> $status (imported from $image_file)"

series_owner="$(bs::series_for_category "$category_id")" || series_owner=""
if [[ -n "$series_owner" ]]; then
  count="$(bs::series_relink "$series_owner" "$quiet")"
  echo "series $series_owner relinked ($count cover(s))"
fi
