readonly BS_IMAGE_WIDTH_DEFAULT=600
readonly BS_IMAGE_HEIGHT_DEFAULT=900
readonly BS_IMAGE_FORMAT_DEFAULT="jpg"

# Resize output dir for series $1, resolution spec $2 -- series/<id>/covers/<spec>/.
bs::series_resized_dir() {
  local dir; dir="$(bs::series_dir "$1")/covers/$2"
  mkdir -p "$dir"
  echo "$dir"
}

# Syncs resize output dir $2 (ext $3) with the covers linked in $1: runs
# `convert $src <args> $out` for each cover whose output is missing or whose
# mtime differs from the cover image's (or every one, if $6 force), then
# gives the output the image's mtime; deletes every other file in $2. $4
# quiet, $5 status-line label. A per-file failure is reported and skipped,
# not fatal. Prints "<converted> <removed>".
bs::_resize_view_dir() {
  local view_dir="$1" out_dir="$2" format="$3" quiet="$4" label="$5" force="$6"; shift 6
  mkdir -p "$out_dir"

  shopt -s nullglob
  local all_src=("$view_dir"/*) all_out=("$out_dir"/*)
  shopt -u nullglob
  local sources=()
  local candidate
  for candidate in "${all_src[@]}"; do
    [[ "$candidate" == *.json ]] && continue
    [[ -L "$candidate" && -e "$candidate" ]] || continue
    sources+=("$candidate")
  done
  local total="${#sources[@]}"

  local -A src_mtime=() out_mtime=() wanted=()
  local mtime path base
  if (( total > 0 )); then
    while read -r mtime path; do
      src_mtime["${path##*/}"]="$mtime"
    done < <(stat -L -c '%Y %n' -- "${sources[@]}")
  fi
  if (( ${#all_out[@]} > 0 )); then
    while read -r mtime path; do
      out_mtime["${path##*/}"]="$mtime"
    done < <(stat -c '%Y %n' -- "${all_out[@]}")
  fi

  local count=0 processed=0 src out name
  for src in "${sources[@]}"; do
    processed=$((processed + 1))
    base="${src##*/}"
    name="${base%.*}.${format}"
    wanted["$name"]=1
    out="${out_dir}/${name}"
    if [[ -z "$force" && "${out_mtime[$name]:-}" == "${src_mtime[$base]}" ]]; then
      continue
    fi
    bs::status_line "${label}[$processed/$total] $base..." "$quiet"
    if convert "$src" "$@" "$out" && touch -r "$src" -- "$out"; then
      count=$((count + 1))
    else
      bs::status_line_clear "$quiet"
      echo "error: failed to resize $src" >&2
    fi
  done

  local removed=0 stale
  for stale in "${all_out[@]}"; do
    [[ -n "${wanted[${stale##*/}]:-}" ]] && continue
    rm -f -- "$stale"
    removed=$((removed + 1))
  done

  bs::status_line_clear "$quiet"
  echo "$count $removed"
}

# Brings series $1's resized covers up to date: first syncs covers/original/
# with its series items (bs::series_relink), then syncs each output folder
# with covers/original/ (bs::_resize_view_dir), converting only what changed
# unless $6 (force). Never touches the originals themselves. $2/$3
# (width/height) given, or no 'resolutions' on the series: pad to WxH on
# white, into covers/<width>x<height>/. Otherwise one pass per resolution
# spec, into covers/<spec>/. Prints "<converted> <removed>" summed over all.
bs::resize_series() {
  local id="$1" width="$2" height="$3" format="$4" quiet="$5" force="$6"
  format="${format:-$(bs::config_get image_format "$BS_IMAGE_FORMAT_DEFAULT")}"

  command -v convert > /dev/null 2>&1 || {
    echo "error: ImageMagick's 'convert' is required for resizing but was not found on \$PATH" >&2
    return 1
  }

  bs::series_relink "$id" "$quiet" > /dev/null || return 1
  local view_dir; view_dir="$(bs::series_dir "$id")/covers/original"

  local resolutions=""
  [[ -z "$width" && -z "$height" ]] && resolutions="$(bs::series_resolutions "$id" | tr '\n' ' ')"

  local converted=0 removed=0 c r
  if [[ -n "${resolutions// /}" ]]; then
    local spec
    for spec in $resolutions; do
      read -r c r <<< "$(bs::_resize_view_dir "$view_dir" "$(bs::series_resized_dir "$id" "$spec")" "$format" "$quiet" "$id $spec " "$force" -resize "$spec")"
      converted=$((converted + c))
      removed=$((removed + r))
    done
  else
    width="${width:-$(bs::config_get image_width "$BS_IMAGE_WIDTH_DEFAULT")}"
    height="${height:-$(bs::config_get image_height "$BS_IMAGE_HEIGHT_DEFAULT")}"
    read -r converted removed <<< "$(bs::_resize_view_dir "$view_dir" "$(bs::series_resized_dir "$id" "${width}x${height}")" "$format" "$quiet" "$id " "$force" \
      -resize "${width}x${height}" -background white -gravity center -extent "${width}x${height}")"
  fi

  echo "$converted $removed"
}
