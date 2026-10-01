: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_ids="${args[series_id]:-}"
width="${args[--width]:-}"
height="${args[--height]:-}"
format="${args[--format]:-}"
force="${args[--force]:-}"
quiet=""
if bs::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

[[ -z "$series_ids" ]] && series_ids="$(bs::all_series_ids | tr '\n' ' ')"

if [[ -z "$series_ids" ]]; then
  echo "No series defined yet."
  exit 0
fi

# shellcheck disable=SC2086 # intentional word-splitting
for id in $series_ids; do
  read -r converted removed <<< "$(bs::resize_series "$id" "$width" "$height" "$format" "$quiet" "$force")" || exit 1
  summary="$converted file(s) resized, $removed stale removed"
  if [[ -n "$width" || -n "$height" ]]; then
    echo "$id -> $summary, to ${width:-$(bs::config_get image_width "$BS_IMAGE_WIDTH_DEFAULT")}x${height:-$(bs::config_get image_height "$BS_IMAGE_HEIGHT_DEFAULT")} (explicit override)"
  else
    resolutions="$(bs::series_resolutions "$id" | tr '\n' ' ')"
    if [[ -n "${resolutions// /}" ]]; then
      echo "$id -> $summary, across resolutions: ${resolutions% }"
    else
      echo "$id -> $summary (see 'beam-shop config list' for the effective width/height/format)"
    fi
  fi
done
