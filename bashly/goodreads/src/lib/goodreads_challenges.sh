# Reading challenges are manually curated, not scraped -- no goodreads.com
# listing to discover them from (challenge detail is behind a step-up-auth
# wall, see CLAUDE.md). challenge_id is a purely local string derived from
# the challenge's own start/end (see gr::generate_challenge_id, below),
# unlike book_id/blog_id, which are goodreads.com's own ids.

gr::challenge_dir() {
  echo "$(gr::data_dir)/challenges"
}

gr::challenge_file() {
  echo "$(gr::challenge_dir)/$1.json"
}

# Errors (return 1) if the challenge doesn't exist; else prints its file
# path -- same shape gr::refresh_book uses.
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

# Creates a challenge with empty blogs/count_badges (see
# gr::add_challenge_blog/count_badge to populate them). Prints the new id.
# $4, if given, is used as-is instead of calling gr::generate_challenge_id
# (see challenges_create_command.sh's own --id, which already checked it
# isn't taken before ever calling this).
gr::create_challenge() {
  local title="$1" start="$2" end="$3" id_override="${4:-}"
  mkdir -p "$(gr::challenge_dir)"

  local id="$id_override"
  [[ -z "$id" ]] && id="$(gr::generate_challenge_id "$start" "$end")"

  # jq's grammar reserves "end" for if/end and can't parse $end as a
  # variable -- confirmed directly. Bind it as end_date instead; the
  # bash-side name stays plain "end" throughout.
  jq -n -S \
    --arg id "$id" \
    --arg title "$title" \
    --arg start "$start" \
    --arg end_date "$end" \
    '{challenge_id: $id, title: $title, start: $start, end: $end_date, blogs: [], count_badges: []}' \
    > "$(gr::challenge_file "$id")"

  echo "$id"
}

# Merges whichever of title/start/end are non-empty onto the existing file;
# blogs/count_badges are always left untouched.
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

# Upserts by blog_id: an existing entry only has its name replaced (order
# preserved), a new one is appended. Empty name stores as null, never "".
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

# Same upsert shape as gr::add_challenge_blog, keyed by count; kept sorted
# by count afterward so display order is always ascending.
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

# Challenge status (planned/ongoing/finished) from start/end vs $today,
# computed once per invocation. Shared by list/get. Unrelated to
# GR_CHALLENGE_JQ_DEFS (goodreads_blogs.sh) despite the name -- that one's
# about a blog post's own candidate flag, this is a challenge's lifecycle.
# shellcheck disable=SC2034 # used cross-file by challenges_list_command.sh/challenges_get_command.sh's jq programs
# shellcheck disable=SC2016 # single-quoted deliberately — this is jq syntax, not bash, and must not expand here
readonly GR_CHALLENGE_STATUS_JQ_DEF='
def challenge_status($today):
  if $today < .start then "planned"
  elif $today > .end then "finished"
  else "ongoing" end;
'

# --- Defaults for `challenges create`. Seasons: Winter/Spring/Summer/Fall
# = Jan-Mar/Apr-Jun/Jul-Sep/Oct-Dec (explicit direction, not the
# Northern-Hemisphere calendar seasons). The two arrays are parallel,
# indexed 0-3.
readonly GR_QUARTER_END_MONTHDAY=(03-31 06-30 09-30 12-31)
readonly GR_QUARTER_SEASON=(Winter Spring Summer Fall)
readonly GR_CHALLENGE_MIN_DAYS=42 # 6 weeks

# --blogs default window: starts this many days before the challenge's
# start, ends this many days before its end (or today if earlier) --
# deliberately asymmetric per explicit direction.
readonly GR_CHALLENGE_BLOG_WINDOW_BEFORE_START_DAYS=7
readonly GR_CHALLENGE_BLOG_WINDOW_BEFORE_END_DAYS=14

# --blogs default likeliness threshold -- higher than goodreads_blogs.sh's
# own GR_CHALLENGE_POTENTIAL_THRESHOLD (0.5), which answers a different
# question (is this a listing at all vs. auto-link it to a new challenge).
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

# Days between two dates ($2 - $1), pinned to UTC -- a local-time
# epoch/86400 diff is off by a day across a DST transition (confirmed
# directly: 2024-03-25 to 2024-04-01 in Europe/Berlin gives 6, not 7).
gr::days_between() {
  local start_epoch end_epoch
  start_epoch="$(date -u -d "$1" +%s)"
  end_epoch="$(date -u -d "$2" +%s)"
  echo $(( (end_epoch - start_epoch) / 86400 ))
}

# The last day of the month right before $1's own month, e.g.
# 2024-03-31 -> 2024-02-29. $1 need not itself be a month-end.
gr::last_day_of_prev_month() {
  date -d "$(date -d "$1" +%Y-%m-01) -1 day" +%Y-%m-%d
}

# The last day of the month right after $1's own month, e.g.
# 2024-03-31 -> 2024-04-30. Three materialized date -d calls, not one
# chained relative string -- confirmed directly GNU date doesn't apply
# chained terms left-to-right ("$1 +1 day +1 month -1 day" gives
# 2024-05-01 for 2024-03-31, not 2024-04-30).
gr::last_day_of_next_month() {
  local next_day plus_month
  next_day="$(date -d "$1 +1 day" +%Y-%m-%d)"
  plus_month="$(date -d "$next_day +1 month" +%Y-%m-%d)"
  date -d "$plus_month -1 day" +%Y-%m-%d
}

# Default --end for a challenge starting on $1: the next quarter-end at or
# after $1, unless under GR_CHALLENGE_MIN_DAYS away, in which case the one
# after that -- e.g. start=2024-09-15 selects 2024-12-31, not 2024-09-30.
gr::default_challenge_end() {
  local start="$1" candidate
  candidate="$(gr::quarter_end_on_or_after "$start")"
  if [[ "$(gr::days_between "$start" "$candidate")" -lt "$GR_CHALLENGE_MIN_DAYS" ]]; then
    candidate="$(gr::next_quarter_end "$candidate")"
  fi
  echo "$candidate"
}

# Every existing challenge's file path, one per line, or nothing -- shared
# by gr::latest_challenge and gr::challenges_overlapping below.
gr::all_challenge_files() {
  local dir file
  dir="$(gr::challenge_dir)"
  [[ -d "$dir" ]] || return 0
  for file in "$dir"/*.json; do
    [[ -e "$file" ]] && echo "$file"
  done
}

# "<id>\t<start>\t<end>" of the existing challenge with the largest .end,
# or empty if there are none -- "latest" by .end, not necessarily .start.
gr::latest_challenge() {
  local files=()
  mapfile -t files < <(gr::all_challenge_files)
  [[ "${#files[@]}" -eq 0 ]] && return 0
  cat "${files[@]}" | jq -s -r 'max_by(.end) | [.challenge_id, .start, .end] | @tsv'
}

# "<id>\t<start>\t<end>" of the existing challenge with the smallest .end
# that's still today or later -- the next one to actually finish, whether
# it's currently ongoing or still merely planned -- or empty if every
# existing challenge has already ended (or there are none at all). Used
# by `challenges get` to pick a sensible default when no id is given; see
# gr::latest_challenge, above, for the "everything's already over"
# fallback that pairs with this.
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

# "<id>\t<start>\t<end>" for every existing challenge overlapping [$1, $2],
# one per line. Used to refuse an *auto-selected* --start that would
# silently collide -- see challenges_create_command.sh.
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

# Default --start: the day after the latest challenge's own end, if a
# hypothetical same-rules successor starting there would still be ongoing
# right now (one test covering both "still ongoing" and "recently ended").
# Otherwise the start of the current quarter -- no prior challenge, or the
# trail went cold long enough ago that continuing from it doesn't make
# sense.
#
# Fails outright instead of either, if the latest challenge hasn't started
# yet ("planned"): chaining off it doesn't make sense, and falling back to
# the quarter start could land back on an *earlier* challenge instead
# (confirmed directly: three successive no-arg `create` calls -- #3's
# latest, #2, is still merely planned, and falling back would silently
# collide with #1). Naming the actual planned challenge here beats letting
# that surface later as a generic overlap error.
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

# "<year>\t<idx>" (idx 0-3, matching GR_QUARTER_SEASON/
# GR_QUARTER_END_MONTHDAY) for the quarter-end within one calendar month
# of $1, else nothing. <year> is the matched quarter-end's own year, not
# necessarily $1's -- 2025-01-15 matches 2024-12-31 (Fall), so this
# reports 2024. Shared by gr::season_title_near and gr::challenge_season,
# so "is this near a quarter-end, and which one" is answered in exactly
# one place.
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

# "<year>\t<quarter>" (quarter 1-4, i.e. idx+1) if the challenge $1 to $2
# is "seasonal" -- the same rule gr::default_challenge_title uses to pick
# a season name for it (at least GR_CHALLENGE_MIN_DAYS long, end within a
# month of a quarter-end) -- else nothing. Shared by
# gr::default_challenge_title and gr::generate_challenge_id, so
# "seasonal or not" can never quietly disagree between a challenge's title
# and its id.
gr::challenge_season() {
  local start="$1" end="$2" match year idx
  [[ "$(gr::days_between "$start" "$end")" -ge "$GR_CHALLENGE_MIN_DAYS" ]] || return
  match="$(gr::quarter_near "$end")"
  [[ -z "$match" ]] && return
  IFS=$'\t' read -r year idx <<<"$match"
  printf '%s\t%s\n' "$year" "$((idx + 1))"
}

# Default --title: "<Season> Challenge <year>" for a seasonal challenge
# (gr::challenge_season); else "Unnamed Challenge".
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

# Chooses a new challenge id, without creating anything (see
# gr::create_challenge) -- "<year>Q<quarter>" for a seasonal challenge
# (gr::challenge_season; e.g. "2026Q3"), falling back to
# "<base>-<counter>" (counter starting at 2) if that id is already taken;
# "<year>-<counter>" (counter starting at 1, straight away -- no bare
# "<year>" attempt first) for a non-seasonal one, keyed off $1's own year
# since there's no quarter-end to anchor to. Existence is checked directly
# against the real challenge files on disk, not any separate counter
# state -- unlike the purely-sequential-integer scheme this replaced, an
# id CAN be reused once its challenge is deleted (see CLAUDE.md).
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

# Default --blogs for a challenge running $1 to $2, as of today ($3):
# every *cached* post (can't discover ones never fetched) published in
# [$1 - GR_CHALLENGE_BLOG_WINDOW_BEFORE_START_DAYS days, min($2 -
# GR_CHALLENGE_BLOG_WINDOW_BEFORE_END_DAYS days, $3)] with
# challenge_potential >= GR_CHALLENGE_BLOG_DEFAULT_MIN_POTENTIAL -- the
# raw likelihood, not gr_challenge_status's derived/overridable boolean.
# One blog_id per line, sorted by .published; nothing if none match.
#
# Capped at today (never past it) because real challenges reveal their
# badges/posts gradually over their own run, not all at once at creation
# -- a post for a badge revealed later genuinely can't exist yet.
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
