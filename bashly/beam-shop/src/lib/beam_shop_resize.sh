readonly BS_IMAGE_WIDTH_DEFAULT=600
readonly BS_IMAGE_HEIGHT_DEFAULT=900
readonly BS_IMAGE_FORMAT_DEFAULT="jpg"

bs::series_resized_dir() {
  local dir; dir="$(bs::data_dir)/series-resized/$1"
  mkdir -p "$dir"
  echo "$dir"
}

# Runs one `convert $src <convert_args> $out` per real (symlinked) cover
# in $1 (a series view folder), writing into $2 (created if needed) with
# extension $3 (the target format). $4 (quiet, see bs::fetch_quiet)
# suppresses the self-updating status line shown per file -- resizing a
# large series (thousands of covers, potentially several resolutions
# each) can take a while even though each individual convert is fast, so
# showing progress matters here too, same reasoning as bs::fetch_category.
# $5 (label) prefixes the status line (e.g. which resolution this pass
# is). Prints how many were successfully converted; a per-file failure is
# reported to stderr (after clearing the status line first) and skipped,
# not fatal to the batch.
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

# Resizes every cover in series $1's view folder. Never touches the
# originals or the symlink view either way. $5 (quiet, see
# bs::fetch_quiet) suppresses the self-updating status line (see
# bs::_resize_view_dir). Prints how many files were written in total. Two
# modes:
#  - $2/$3 (width/height) given, or the series has no 'resolutions' of
#    its own: the single-profile legacy behavior -- pad to exactly
#    WxH (never cropping content) on a white background, written flat
#    into series-resized/$1/. $2/$3/$4 (width/height/format) fall back to
#    their own config keys (see beam_shop_config.sh) when empty; an
#    explicit $2/$3 always wins over the series' own resolutions, for a
#    quick one-off override without touching the series definition.
#  - otherwise (no $2/$3 override, series has 'resolutions'): one pass
#    per resolution spec -- a raw ImageMagick geometry string (e.g.
#    '700x1000!'), passed straight to -resize with none of the padding
#    logic above -- into series-resized/$1/<spec>/, one subfolder per
#    spec, so several sizes/aspect-ratio behaviors can coexist.
bs::resize_series() {
  local id="$1" width="$2" height="$3" format="$4" quiet="$5"
  format="${format:-$(bs::config_get image_format "$BS_IMAGE_FORMAT_DEFAULT")}"

  command -v convert > /dev/null 2>&1 || {
    echo "error: ImageMagick's 'convert' is required for resizing but was not found on \$PATH" >&2
    return 1
  }

  local view_dir; view_dir="$(bs::series_view_dir "$id")"
  [[ -d "$view_dir" ]] || { echo "error: no series view for '$id' -- run 'series relink $id' first" >&2; return 1; }

  local resolutions=""
  [[ -z "$width" && -z "$height" ]] && resolutions="$(bs::series_resolutions "$id" | tr '\n' ' ')"

  local total=0
  if [[ -n "${resolutions// /}" ]]; then
    local spec n
    for spec in $resolutions; do
      n="$(bs::_resize_view_dir "$view_dir" "$(bs::data_dir)/series-resized/${id}/${spec}" "$format" "$quiet" "$id $spec " -resize "$spec")"
      total=$((total + n))
    done
  else
    width="${width:-$(bs::config_get image_width "$BS_IMAGE_WIDTH_DEFAULT")}"
    height="${height:-$(bs::config_get image_height "$BS_IMAGE_HEIGHT_DEFAULT")}"
    total="$(bs::_resize_view_dir "$view_dir" "$(bs::series_resized_dir "$id")" "$format" "$quiet" "$id " \
      -resize "${width}x${height}" -background white -gravity center -extent "${width}x${height}")"
  fi

  echo "$total"
}
