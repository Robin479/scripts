: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
image_file="${args[image_file]}"
product_id="${args[--product]:-}"
category_id="${args[--category]:-}"
title="${args[--title]:-}"
series_id="${args[--series]:-}"
item_number="${args[--item]:-}"
force="${args[--force]:-}"
quiet=""
if bs::fetch_quiet ""; then
  quiet=1
fi

# manual_given: --product/--category given (not --title -- that alone doesn't decide the form)
manual_given=0
[[ -n "$product_id" || -n "$category_id" ]] && manual_given=1
lookup_given=0
[[ -n "$series_id" || -n "$item_number" ]] && lookup_given=1

if [[ "$manual_given" -eq 1 && "$lookup_given" -eq 1 ]]; then
  echo "error: give either --product/--category(/--title), or --series/--item(/--title), not both" >&2
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

  if found="$(bs::find_series_item "$series_id" "$item_number")"; then
    product_id="$(jq -r '.product_id' <<< "$found")"
    category_id="$(bs::categories_for_product "$product_id" | head -1)"
    title="$(jq -r '.title' <<< "$found")"

    status="$(bs::import_cover "$category_id" "$product_id" "$image_file" "$title" "$force" "$quiet")" || exit 1
    echo "$product_id -> $status (imported from $image_file)"
  else
    if [[ -z "$title" ]]; then
      echo "error: no existing record for series '$series_id' item $item_number, so there's no product to resolve a title from -- pass --title yourself for a fully-manual entry (or use --product/--category/--title if you actually know its shop product id)." >&2
      exit 1
    fi
    status="$(bs::import_manual_cover "$series_id" "$item_number" "$image_file" "$title" "$force" "$quiet")" || exit 1
    echo "series $series_id item $item_number -> $status (imported from $image_file, no shop product)"
  fi
elif [[ "$manual_given" -eq 1 ]]; then
  if [[ -z "$product_id" ]]; then
    echo "error: --category alone isn't enough -- give --product too (or use --series/--item instead)" >&2
    exit 1
  fi

  product_file="$(bs::product_file "$product_id")"
  if [[ -f "$product_file" ]]; then
    [[ -n "$title" ]] || title="$(jq -r '.title' "$product_file")"
    [[ -n "$category_id" ]] || category_id="$(bs::categories_for_product "$product_id" | head -1)"
  elif [[ -z "$title" ]]; then
    echo "error: no existing record for product $product_id, so there's no title to fall back on -- pass --title yourself for a brand-new product." >&2
    exit 1
  fi

  status="$(bs::import_cover "$category_id" "$product_id" "$image_file" "$title" "$force" "$quiet")" || exit 1
  echo "$product_id -> $status (imported from $image_file)"
else
  echo "error: give --product (plus --category/--title only if needed), or --series and --item (plus --title for a fully-manual entry)" >&2
  exit 1
fi

