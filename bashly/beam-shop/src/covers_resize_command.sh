: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_ids="${args[series_id]:-}"
width="${args[--width]:-}"
height="${args[--height]:-}"
format="${args[--format]:-}"
# Must be a plain if (see bs::fetch_quiet's doc comment, lib/beam_shop.sh)
# -- a command substitution silently breaks its terminal check.
quiet=""
if bs::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

if [[ -z "$series_ids" ]]; then
  shopt -s nullglob
  files=("$(bs::series_root)"/*.json)
  shopt -u nullglob
  ids=()
  for f in "${files[@]}"; do
    ids+=("$(jq -r '.series_id' "$f")")
  done
  series_ids="${ids[*]}"
fi

if [[ -z "$series_ids" ]]; then
  echo "No series defined yet."
  exit 0
fi

# shellcheck disable=SC2086 # word-splitting is exactly what's wanted — series_ids is bashly's own space-separated repeatable-arg string, or built the same way just above
for id in $series_ids; do
  count="$(bs::resize_series "$id" "$width" "$height" "$format" "$quiet")" || exit 1
  if [[ -n "$width" || -n "$height" ]]; then
    echo "$id -> $count file(s) resized to ${width:-$(bs::config_get image_width "$BS_IMAGE_WIDTH_DEFAULT")}x${height:-$(bs::config_get image_height "$BS_IMAGE_HEIGHT_DEFAULT")} (explicit override)"
  else
    resolutions="$(bs::series_resolutions "$id" | tr '\n' ' ')"
    if [[ -n "${resolutions// /}" ]]; then
      echo "$id -> $count file(s) resized across resolutions: ${resolutions% }"
    else
      echo "$id -> $count file(s) resized (see 'beam-shop config list' for the effective width/height/format)"
    fi
  fi
done
