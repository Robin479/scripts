gr::challenge_dir() {
  echo "$(gr::data_dir)/challenges"
}

gr::challenge_file() {
  echo "$(gr::challenge_dir)/$1.json"
}

# Prints challenge $1's file path, or errors (return 1) if it doesn't exist.
gr::require_challenge_file() {
  local id="$1"
  local file
  file="$(gr::challenge_file "$id")"
  if [[ ! -f "$file" ]]; then
    echo "error: no challenge $id" >&2
    return 1
  fi
  echo "$file"
}

# Creates a challenge with empty blogs/count_badges and prints its id.
# $4, if given, is used as the id instead of gr::generate_challenge_id.
gr::create_challenge() {
  local title="$1" start="$2" end="$3" id_override="${4:-}"
  mkdir -p "$(gr::challenge_dir)"

  local id="$id_override"
  [[ -z "$id" ]] && id="$(gr::generate_challenge_id "$start" "$end")"

  # jq can't parse $end (reserved keyword), hence $end_date.
  jq -n -S \
    --arg id "$id" \
    --arg title "$title" \
    --arg start "$start" \
    --arg end_date "$end" \
    '{challenge_id: $id, title: $title, start: $start, end: $end_date, blogs: [], count_badges: []}' \
    > "$(gr::challenge_file "$id")"

  echo "$id"
}

# Sets whichever of title/start/end are non-empty.
gr::update_challenge() {
  local id="$1" title="$2" start="$3" end="$4"
  local file
  file="$(gr::require_challenge_file "$id")" || return 1

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  # end_date, not end -- see gr::create_challenge.
  jq -S \
    --arg title "$title" \
    --arg start "$start" \
    --arg end_date "$end" \
    '
      (if $title != "" then .title = $title else . end)
      | (if $start != "" then .start = $start else . end)
      | (if $end_date != "" then .end = $end_date else . end)
    ' "$file" > "$tmp_file" || return 1

  mv "$tmp_file" "$file"
}

# Upserts by blog_id (existing entry keeps its position); empty name -> null.
gr::add_challenge_blog() {
  local id="$1" blog_id="$2" name="${3:-}"
  local file
  file="$(gr::require_challenge_file "$id")" || return 1

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  jq -S \
    --arg blog_id "$blog_id" \
    --arg name "$name" \
    '
      ($name | if . == "" then null else . end) as $name
      | if any(.blogs[]?; .blog_id == $blog_id) then
          .blogs |= map(if .blog_id == $blog_id then .name = $name else . end)
        else
          .blogs += [{blog_id: $blog_id, name: $name}]
        end
    ' "$file" > "$tmp_file" || return 1

  mv "$tmp_file" "$file"
}

# Returns 1 (nothing written) if blog_id isn't on the challenge.
gr::remove_challenge_blog() {
  local id="$1" blog_id="$2"
  local file
  file="$(gr::require_challenge_file "$id")" || return 1

  if ! jq -e --arg blog_id "$blog_id" 'any(.blogs[]?; .blog_id == $blog_id)' "$file" > /dev/null; then
    return 1
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  jq -S --arg blog_id "$blog_id" '.blogs |= map(select(.blog_id != $blog_id))' "$file" > "$tmp_file" || return 1
  mv "$tmp_file" "$file"
}

# Upserts by count, like gr::add_challenge_blog; kept sorted by count.
gr::add_challenge_count_badge() {
  local id="$1" count="$2" name="${3:-}"
  local file
  file="$(gr::require_challenge_file "$id")" || return 1

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  jq -S \
    --argjson count "$count" \
    --arg name "$name" \
    '
      ($name | if . == "" then null else . end) as $name
      | if any(.count_badges[]?; .count == $count) then
          .count_badges |= map(if .count == $count then .name = $name else . end)
        else
          .count_badges += [{count: $count, name: $name}]
        end
      | .count_badges |= sort_by(.count)
    ' "$file" > "$tmp_file" || return 1

  mv "$tmp_file" "$file"
}

# Returns 1 (nothing written) if count isn't on the challenge.
gr::remove_challenge_count_badge() {
  local id="$1" count="$2"
  local file
  file="$(gr::require_challenge_file "$id")" || return 1

  if ! jq -e --argjson count "$count" 'any(.count_badges[]?; .count == $count)' "$file" > /dev/null; then
    return 1
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  jq -S --argjson count "$count" '.count_badges |= map(select(.count != $count))' "$file" > "$tmp_file" || return 1
  mv "$tmp_file" "$file"
}

# Empty .blogs / .count_badges.
gr::clear_challenge_blogs() {
  gr::clear_challenge_array "$1" blogs
}

gr::clear_challenge_count_badges() {
  gr::clear_challenge_array "$1" count_badges
}

gr::clear_challenge_array() {
  local id="$1" field="$2"
  local file
  file="$(gr::require_challenge_file "$id")" || return 1

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  jq -S --arg field "$field" '.[$field] = []' "$file" > "$tmp_file" || return 1
  mv "$tmp_file" "$file"
}

# jq def: planned/ongoing/finished from start/end vs $today (YYYY-MM-DD).
# shellcheck disable=SC2034 # used by challenges_list/challenges_get command jq programs
# shellcheck disable=SC2016 # jq syntax, must not expand
readonly GR_CHALLENGE_STATUS_JQ_DEF='
def challenge_status($today):
  if $today < .start then "planned"
  elif $today > .end then "finished"
  else "ongoing" end;
'

# --- Defaults for `challenges create`. Parallel arrays, indexed by quarter 0-3.
readonly GR_QUARTER_END_MONTHDAY=(03-31 06-30 09-30 12-31)
readonly GR_QUARTER_SEASON=(Winter Spring Summer Fall)
readonly GR_CHALLENGE_MIN_DAYS=42 # 6 weeks

# --blogs default window: [start - 7 days, min(end - 14 days, today)].
readonly GR_CHALLENGE_BLOG_WINDOW_BEFORE_START_DAYS=7
readonly GR_CHALLENGE_BLOG_WINDOW_BEFORE_END_DAYS=14

# --blogs default minimum challenge_potential.
readonly GR_CHALLENGE_BLOG_DEFAULT_MIN_POTENTIAL=0.7

# Index (0-3) of the quarter $1 (YYYY-MM-DD) falls in.
gr::quarter_index() {
  local month
  month="$(date -d "$1" +%-m)"
  echo $(( (month - 1) / 3 ))
}

# The quarter-end date (one of the 4 fixed boundaries) that is >= $1.
gr::quarter_end_on_or_after() {
  local year idx
  year="$(date -d "$1" +%Y)"
  idx="$(gr::quarter_index "$1")"
  echo "${year}-${GR_QUARTER_END_MONTHDAY[idx]}"
}

# The next quarter-end strictly after $1 (itself one of the 4 boundaries).
gr::next_quarter_end() {
  local year idx next_idx next_year
  year="$(date -d "$1" +%Y)"
  idx="$(gr::quarter_index "$1")"
  next_idx=$(( (idx + 1) % 4 ))
  next_year="$year"
  [[ "$next_idx" -eq 0 ]] && next_year=$((year + 1))
  echo "${next_year}-${GR_QUARTER_END_MONTHDAY[next_idx]}"
}

# The start of the calendar quarter $1 (YYYY-MM-DD) falls in.
gr::quarter_start_of() {
  local year idx month
  year="$(date -d "$1" +%Y)"
  idx="$(gr::quarter_index "$1")"
  month=$(( idx * 3 + 1 ))
  printf '%04d-%02d-01\n' "$year" "$month"
}

# Days from $1 to $2. UTC, since a local-time diff is off by one across DST.
gr::days_between() {
  local start_epoch end_epoch
  start_epoch="$(date -u -d "$1" +%s)"
  end_epoch="$(date -u -d "$2" +%s)"
  echo $(( (end_epoch - start_epoch) / 86400 ))
}

# Last day of the month before $1's, e.g. 2024-03-31 -> 2024-02-29.
gr::last_day_of_prev_month() {
  date -d "$(date -d "$1" +%Y-%m-01) -1 day" +%Y-%m-%d
}

# Last day of the month after $1's, e.g. 2024-03-31 -> 2024-04-30.
# Separate date -d steps: GNU date doesn't apply chained relative terms in
# order ("+1 day +1 month -1 day" gives 2024-05-01 here).
gr::last_day_of_next_month() {
  local next_day plus_month
  next_day="$(date -d "$1 +1 day" +%Y-%m-%d)"
  plus_month="$(date -d "$next_day +1 month" +%Y-%m-%d)"
  date -d "$plus_month -1 day" +%Y-%m-%d
}

# Default --end: the first quarter-end at least GR_CHALLENGE_MIN_DAYS after $1.
gr::default_challenge_end() {
  local start="$1" candidate
  candidate="$(gr::quarter_end_on_or_after "$start")"
  if [[ "$(gr::days_between "$start" "$candidate")" -lt "$GR_CHALLENGE_MIN_DAYS" ]]; then
    candidate="$(gr::next_quarter_end "$candidate")"
  fi
  echo "$candidate"
}

# Every challenge file path, one per line.
gr::all_challenge_files() {
  local dir file
  dir="$(gr::challenge_dir)"
  [[ -d "$dir" ]] || return 0
  for file in "$dir"/*.json; do
    [[ -e "$file" ]] && echo "$file"
  done
}

# "<id>\t<start>\t<end>" of the challenge with the largest .end, or nothing.
gr::latest_challenge() {
  local files=()
  mapfile -t files < <(gr::all_challenge_files)
  [[ "${#files[@]}" -eq 0 ]] && return 0
  cat "${files[@]}" | jq -s -r 'max_by(.end) | [.challenge_id, .start, .end] | @tsv'
}

# "<id>\t<start>\t<end>" of the challenge with the smallest .end >= $1
# (today), or nothing.
gr::next_ending_challenge() {
  local today="$1" files=()
  mapfile -t files < <(gr::all_challenge_files)
  [[ "${#files[@]}" -eq 0 ]] && return 0
  cat "${files[@]}" | jq -s -r --arg today "$today" '
    map(select(.end >= $today))
    | if length == 0 then empty else min_by(.end) end
    | [.challenge_id, .start, .end] | @tsv
  '
}

# "<id>\t<start>\t<end>" of every challenge overlapping [$1, $2].
gr::challenges_overlapping() {
  local start="$1" end="$2" files=()
  mapfile -t files < <(gr::all_challenge_files)
  [[ "${#files[@]}" -eq 0 ]] && return 0
  # end_date, not end -- see gr::create_challenge.
  cat "${files[@]}" | jq -s -r --arg start "$start" --arg end_date "$end" '
    .[] | select(.start <= $end_date and .end >= $start)
    | [.challenge_id, .start, .end] | @tsv
  '
}

# Default --start as of $1 (today): the day after the latest challenge's
# end if a default-length successor from there hasn't ended yet, else the
# current quarter's start. Fails if the latest challenge is still planned.
gr::default_challenge_start() {
  local today="$1" latest latest_id latest_start latest_end
  local candidate_start candidate_end
  latest="$(gr::latest_challenge)"

  if [[ -n "$latest" ]]; then
    IFS=$'\t' read -r latest_id latest_start latest_end <<<"$latest"

    if [[ "$today" < "$latest_start" ]]; then
      echo "error: the latest challenge (challenge $latest_id, $latest_start to $latest_end) hasn't started yet -- can't auto-select --start from it. Pass --start explicitly." >&2
      return 1
    fi

    candidate_start="$(date -d "$latest_end +1 day" +%Y-%m-%d)"
    candidate_end="$(gr::default_challenge_end "$candidate_start")"
    if [[ ! "$candidate_end" < "$today" ]]; then
      echo "$candidate_start"
      return
    fi
  fi

  gr::quarter_start_of "$today"
}

# "<year>\t<idx>" of the quarter-end within one calendar month of $1, else
# nothing. <year> is the quarter-end's (2025-01-15 -> 2024, idx 3).
gr::quarter_near() {
  local d="$1" base_year check_year idx q_end window_start window_end
  base_year="$(date -d "$d" +%Y)"
  for check_year in $((base_year - 1)) "$base_year" $((base_year + 1)); do
    for idx in 0 1 2 3; do
      q_end="${check_year}-${GR_QUARTER_END_MONTHDAY[idx]}"
      window_start="$(gr::last_day_of_prev_month "$q_end")"
      window_end="$(gr::last_day_of_next_month "$q_end")"
      if [[ ! "$d" < "$window_start" ]] && [[ ! "$d" > "$window_end" ]]; then
        printf '%s\t%s\n' "$check_year" "$idx"
        return
      fi
    done
  done
}

# "<Season> Challenge <year>" if $1 (an end date) falls within one
# calendar month of a quarter-end, else empty.
gr::season_title_near() {
  local match year idx
  match="$(gr::quarter_near "$1")"
  [[ -z "$match" ]] && return
  IFS=$'\t' read -r year idx <<<"$match"
  echo "${GR_QUARTER_SEASON[idx]} Challenge ${year}"
}

# "<year>\t<quarter 1-4>" if the challenge $1..$2 is seasonal (at least
# GR_CHALLENGE_MIN_DAYS long, end near a quarter-end), else nothing.
# Shared by the default title and the id so they always agree.
gr::challenge_season() {
  local start="$1" end="$2" match year idx
  [[ "$(gr::days_between "$start" "$end")" -ge "$GR_CHALLENGE_MIN_DAYS" ]] || return
  match="$(gr::quarter_near "$end")"
  [[ -z "$match" ]] && return
  IFS=$'\t' read -r year idx <<<"$match"
  printf '%s\t%s\n' "$year" "$((idx + 1))"
}

# Default --title: "<Season> Challenge <year>" if seasonal, else "Unnamed Challenge".
gr::default_challenge_title() {
  local start="$1" end="$2" season year quarter
  season="$(gr::challenge_season "$start" "$end")"
  if [[ -n "$season" ]]; then
    IFS=$'\t' read -r year quarter <<<"$season"
    echo "${GR_QUARTER_SEASON[$((quarter - 1))]} Challenge ${year}"
    return
  fi
  echo "Unnamed Challenge"
}

# First free id: "<year>Q<quarter>" (then "-2", "-3", ...) if seasonal,
# else "<start year>-<n>" from n=1. Checks existing files only.
gr::generate_challenge_id() {
  local start="$1" end="$2" season year quarter base counter

  season="$(gr::challenge_season "$start" "$end")"
  if [[ -n "$season" ]]; then
    IFS=$'\t' read -r year quarter <<<"$season"
    base="${year}Q${quarter}"
    if [[ ! -f "$(gr::challenge_file "$base")" ]]; then
      echo "$base"
      return
    fi
    counter=2
    while [[ -f "$(gr::challenge_file "${base}-${counter}")" ]]; do
      counter=$((counter + 1))
    done
    echo "${base}-${counter}"
    return
  fi

  year="$(date -d "$start" +%Y)"
  counter=1
  while [[ -f "$(gr::challenge_file "${year}-${counter}")" ]]; do
    counter=$((counter + 1))
  done
  echo "${year}-${counter}"
}

# Default --blogs for a challenge $1..$2 as of $3 (today): cached posts
# published in the window (see constants above) with raw
# challenge_potential >= GR_CHALLENGE_BLOG_DEFAULT_MIN_POTENTIAL, one
# blog_id per line, oldest first.
gr::default_challenge_blogs() {
  local start="$1" end="$2" today="$3" window_start window_end
  window_start="$(date -d "$start -${GR_CHALLENGE_BLOG_WINDOW_BEFORE_START_DAYS} days" +%Y-%m-%d)"
  window_end="$(date -d "$end -${GR_CHALLENGE_BLOG_WINDOW_BEFORE_END_DAYS} days" +%Y-%m-%d)"
  [[ "$today" < "$window_end" ]] && window_end="$today"

  local dir file files=()
  dir="$(gr::blog_dir)"
  [[ -d "$dir" ]] || return 0
  for file in "$dir"/*.json; do
    [[ -e "$file" ]] && files+=("$file")
  done
  [[ "${#files[@]}" -eq 0 ]] && return 0

  cat "${files[@]}" | jq -s -r \
    --arg since "$window_start" \
    --arg until "$window_end" \
    --argjson min_potential "$GR_CHALLENGE_BLOG_DEFAULT_MIN_POTENTIAL" '
      map(select(
        (.published != null) and (.published >= $since) and (.published <= $until)
        and ((.challenge_potential // 0) >= $min_potential)
      ))
      | sort_by(.published)
      | .[].blog_id
    '
}
