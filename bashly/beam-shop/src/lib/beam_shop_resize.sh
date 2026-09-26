readonly BS_IMAGE_WIDTH_DEFAULT=600
readonly BS_IMAGE_HEIGHT_DEFAULT=900
readonly BS_IMAGE_FORMAT_DEFAULT="jpg"

# Resize output dir for series $1, resolution spec $2 -- series/<id>/covers/<spec>/.
bs::series_resized_dir() {
  local dir; dir="$(bs::series_dir "$1")/covers/$2"
  mkdir -p "$dir"
  echo "$dir"
}

# Runs `convert $src <args> $out` per symlinked cover in $1, into $2 (ext
# $3). $4=quiet, $5=status-line label. Prints count converted; a per-file
# failure is reported and skipped, not fatal.
bs::_resize_view_dir() {
  local view_dir="$1" out_dir="$2" format="$3" quiet="$4" label="$5"; shift 5
  mkdir -p "$out_dir"

  shopt -s nullglob
  local all_src=("$view_dir"/*)
  shopt -u nullglob
  local sources=()
  local candidate
  for candidate in "${all_src[@]}"; do
    [[ "$candidate" == *.json ]] && continue
    [[ -L "$candidate" ]] || continue
    sources+=("$candidate")
  done
  local total="${#sources[@]}"

  local count=0 processed=0 src base out
  for src in "${sources[@]}"; do
    processed=$((processed + 1))
    base="$(basename "$src")"
    bs::status_line "${label}[$processed/$total] $base..." "$quiet"

    out="${out_dir}/${base%.*}.${format}"
    if convert "$src" "$@" "$out"; then
      count=$((count + 1))
    else
      bs::status_line_clear "$quiet"
      echo "error: failed to resize $src" >&2
    fi
  done
  bs::status_line_clear "$quiet"
  echo "$count"
}

# Resizes every cover in series $1's covers/original/ (never touched
# itself). Prints total files written. $2/$3 (width/height) given, or no
# 'resolutions' on the series: pad to WxH on white, into
# covers/<width>x<height>/. Otherwise one pass per resolution spec, into
# covers/<spec>/.
bs::resize_series() {
  local id="$1" width="$2" height="$3" format="$4" quiet="$5"
  format="${format:-$(bs::config_get image_format "$BS_IMAGE_FORMAT_DEFAULT")}"

  command -v convert > /dev/null 2>&1 || {
    echo "error: ImageMagick's 'convert' is required for resizing but was not found on \$PATH" >&2
    return 1
  }

  local view_dir; view_dir="$(bs::series_dir "$id")/covers/original"
  [[ -d "$view_dir" ]] || { echo "error: no covers linked yet for '$id' -- run 'series rebuild $id' first (or 'series rebuild $id --covers-only' if it's already classified but the file tree itself needs repairing)" >&2; return 1; }

  local resolutions=""
  [[ -z "$width" && -z "$height" ]] && resolutions="$(bs::series_resolutions "$id" | tr '\n' ' ')"

  local total=0
  if [[ -n "${resolutions// /}" ]]; then
    local spec n
    for spec in $resolutions; do
      n="$(bs::_resize_view_dir "$view_dir" "$(bs::series_resized_dir "$id" "$spec")" "$format" "$quiet" "$id $spec " -resize "$spec")"
      total=$((total + n))
    done
  else
    width="${width:-$(bs::config_get image_width "$BS_IMAGE_WIDTH_DEFAULT")}"
    height="${height:-$(bs::config_get image_height "$BS_IMAGE_HEIGHT_DEFAULT")}"
    total="$(bs::_resize_view_dir "$view_dir" "$(bs::series_resized_dir "$id" "${width}x${height}")" "$format" "$quiet" "$id " \
      -resize "${width}x${height}" -background white -gravity center -extent "${width}x${height}")"
  fi

  echo "$total"
}
