# Request pacing shared by all goodreads processes via one flock'd state
# file (see CLAUDE.md): a minimum interval between request starts, and a
# shared pause after a bot challenge, followed by spaced-out probes.
# Entry points: gr::throttle before each request, gr::pace_report after.

# Defaults for the pacing config keys (seconds, except _probe_pct and
# _max_probes).
readonly GR_HTTP_REQUEST_INTERVAL_DEFAULT=5
readonly GR_HTTP_CHALLENGE_PAUSE_DEFAULT=300
readonly GR_HTTP_CHALLENGE_PROBE_PCT_DEFAULT=10
readonly GR_HTTP_CHALLENGE_MAX_PROBES_DEFAULT=35

# Fixed tuning, not config keys.
readonly GR_HTTP_PACE_JITTER_PCT=50                # random extra per gap, % of the interval
readonly GR_HTTP_PACE_INCIDENT_END_SUCCESSES=3     # successes in a row that end an incident...
readonly GR_HTTP_PACE_INCIDENT_END_MS=120000       # ...spanning at least this long
readonly GR_HTTP_PACE_INCIDENT_FORGET_MS=1800000   # idle incident is forgotten after this
readonly GR_HTTP_PACE_PROBE_MIN_MS=1000            # shortest probe pause

# Numeric fields of the state file, all integers, times in epoch ms:
#   next_ms             earliest start of the next request, any process
#   cooldown_ms         no request before this either (set by a challenge)
#   challenges          challenges in the current incident, across processes (0 = none open)
#   incident_started_ms start of the incident's first challenged request
#   incident_successes  successes since the incident's last challenge
#   incident_ok_since_ms  start of the first of those successes
#   challenge_at        when the last challenge was recorded
#   last_request_ms     start of the most recent request, any process
#   streak_*, prev_streak_*  diagnostics only: current/previous run of same-kind responses
# Text fields: note (last challenge, shown while pausing), *_kind (ok/challenge),
# instances (recent PIDs, for the log's `first` column).
readonly GR_PACE_FIELDS=(
  next_ms cooldown_ms challenges incident_started_ms incident_successes
  incident_ok_since_ms challenge_at last_request_ms
  streak_started_ms streak_last_ms streak_requests streak_gaps
  streak_gap_min_ms streak_gap_max_ms streak_gap_sum_ms
  prev_streak_started_ms prev_streak_ended_ms prev_streak_requests
  prev_streak_gap_min_ms prev_streak_gap_avg_ms prev_streak_gap_max_ms
)
readonly GR_PACE_TEXT_FIELDS=(note streak_kind prev_streak_kind instances)
readonly GR_PACE_MAX_INSTANCES=16
# gr::pace_log_file is rotated to <file>.1 at this size.
readonly GR_PACE_LOG_MAX_BYTES=$((10 * 1024 * 1024))
declare -A GR_PACE=()

# Set by gr::pace_claim, read by gr::pace_record (same subshell): start of
# this process's latest request, gap since the previous request start (any
# process; empty if none), and whether it's this process's first (1/0).
GR_PACE_CLAIMED_MS=0
GR_PACE_GAP_MS=""
GR_PACE_FIRST=0

gr::pace_file() {
  echo "$(gr::data_dir)/.pacing"
}

# TSV history, one line per classified response (see gr::pace_log).
gr::pace_log_file() {
  echo "$(gr::data_dir)/.pacing.log"
}

gr::now_ms() {
  date +%s%3N
}

# 1500 -> 1.500, for sleep(1) and messages.
gr::ms_to_s() {
  printf '%d.%03d' "$(($1 / 1000))" "$(($1 % 1000))"
}

# Runs "$@" under an exclusive flock(1) on the state (unlocked if flock
# isn't installed). Never hold it across a sleep.
gr::pace_locked() {
  local lock fd rc=0
  lock="$(gr::pace_file).lock"
  exec {fd}>>"$lock"
  if command -v flock > /dev/null 2>&1; then
    flock "$fd"
  fi
  "$@" || rc=$?
  exec {fd}>&-
  return "$rc"
}

# Reads the config keys into GR_PACE_INTERVAL_MS/GR_PACE_PAUSE_MS/
# GR_PACE_PROBE_PCT/GR_PACE_MAX_PROBES.
gr::pace_settings() {
  GR_PACE_INTERVAL_MS=$(( $(gr::config_get http_request_interval "$GR_HTTP_REQUEST_INTERVAL_DEFAULT") * 1000 ))
  GR_PACE_PAUSE_MS=$(( $(gr::config_get http_challenge_pause "$GR_HTTP_CHALLENGE_PAUSE_DEFAULT") * 1000 ))
  GR_PACE_PROBE_PCT="$(gr::config_get http_challenge_probe_pct "$GR_HTTP_CHALLENGE_PROBE_PCT_DEFAULT")"
  GR_PACE_MAX_PROBES="$(gr::config_get http_challenge_max_probes "$GR_HTTP_CHALLENGE_MAX_PROBES_DEFAULT")"
}

gr::pace_is_text_field() {
  local f
  for f in "${GR_PACE_TEXT_FIELDS[@]}"; do
    [[ "$f" == "$1" ]] && return 0
  done
  return 1
}

# Loads the state file into GR_PACE; missing/garbled values default to
# 0/empty, unknown fields are dropped on the next save.
gr::pace_load() {
  GR_PACE=()
  local file k v
  file="$(gr::pace_file)"
  if [[ -f "$file" ]]; then
    while IFS='=' read -r k v; do
      if gr::pace_is_text_field "$k"; then
        GR_PACE[$k]="$v"
      elif [[ "$v" =~ ^[0-9]+$ ]]; then
        GR_PACE[$k]="$v"
      fi
    done < "$file"
  fi
  for k in "${GR_PACE_FIELDS[@]}"; do
    : "${GR_PACE[$k]:=0}"
  done
  for k in "${GR_PACE_TEXT_FIELDS[@]}"; do
    : "${GR_PACE[$k]:=}"
  done
}

# Writes GR_PACE back atomically (temp file + mv).
gr::pace_save() {
  local file tmp k
  file="$(gr::pace_file)"
  tmp="$(mktemp "$file.XXXXXX")"
  {
    for k in "${GR_PACE_FIELDS[@]}" "${GR_PACE_TEXT_FIELDS[@]}"; do
      printf '%s=%s\n' "$k" "${GR_PACE[$k]}"
    done
  } > "$tmp"
  mv "$tmp" "$file"
}

# Forgets an open incident idle (since last request or pause end) for
# GR_HTTP_PACE_INCIDENT_FORGET_MS.
gr::pace_forget_stale_incident() {
  local now="$1" since
  (( GR_PACE[challenges] > 0 )) || return 0
  since=${GR_PACE[last_request_ms]}
  if (( GR_PACE[cooldown_ms] > since )); then
    since=${GR_PACE[cooldown_ms]}
  fi
  if (( now - since >= GR_HTTP_PACE_INCIDENT_FORGET_MS )); then
    GR_PACE[challenges]=0
    GR_PACE[incident_successes]=0
  fi
}

# Under the lock: claims the next request slot if it's due, else leaves
# how long to wait in GR_PACE_WAIT_MS (0 = claimed) and whether that wait
# is a challenge pause in GR_PACE_WAIT_COOLDOWN (1/0).
gr::pace_claim() {
  gr::pace_settings
  gr::pace_load
  local now ready
  now="$(gr::now_ms)"
  gr::pace_forget_stale_incident "$now"

  ready=${GR_PACE[next_ms]}
  GR_PACE_WAIT_COOLDOWN=0
  if (( GR_PACE[cooldown_ms] >= ready )); then
    ready=${GR_PACE[cooldown_ms]}
    GR_PACE_WAIT_COOLDOWN=1
  fi

  if (( ready > now )); then
    GR_PACE_WAIT_MS=$((ready - now))
  else
    local jitter_max=$((GR_PACE_INTERVAL_MS * GR_HTTP_PACE_JITTER_PCT / 100))
    local jitter=$(( ((RANDOM << 15) | RANDOM) % (jitter_max + 1) ))
    GR_PACE[next_ms]=$((now + GR_PACE_INTERVAL_MS + jitter))
    GR_PACE_CLAIMED_MS=$now
    GR_PACE_WAIT_MS=0

    GR_PACE_GAP_MS=""
    if (( GR_PACE[last_request_ms] > 0 )); then
      GR_PACE_GAP_MS=$((now - GR_PACE[last_request_ms]))
    fi
    GR_PACE[last_request_ms]=$now
    # $$ is the main PID even in gr::run_fetch's per-item subshells.
    GR_PACE_FIRST=0
    if [[ ",${GR_PACE[instances]}," != *",$$,"* ]]; then
      GR_PACE_FIRST=1
      local -a pids
      IFS=',' read -r -a pids <<< "$$${GR_PACE[instances]:+,${GR_PACE[instances]}}"
      GR_PACE[instances]="$(IFS=','; echo "${pids[*]:0:GR_PACE_MAX_INSTANCES}")"
    fi
  fi
  gr::pace_save
}

# Diagnostics only: counts this response into the streak stats, archiving
# the old streak as prev_streak_* when the kind changes.
gr::pace_track_streak() {
  local kind="$1"
  if [[ "${GR_PACE[streak_kind]}" != "$kind" ]]; then
    if (( GR_PACE[streak_requests] > 0 )); then
      GR_PACE[prev_streak_kind]=${GR_PACE[streak_kind]}
      GR_PACE[prev_streak_started_ms]=${GR_PACE[streak_started_ms]}
      GR_PACE[prev_streak_ended_ms]=${GR_PACE[streak_last_ms]}
      GR_PACE[prev_streak_requests]=${GR_PACE[streak_requests]}
      GR_PACE[prev_streak_gap_min_ms]=${GR_PACE[streak_gap_min_ms]}
      GR_PACE[prev_streak_gap_max_ms]=${GR_PACE[streak_gap_max_ms]}
      GR_PACE[prev_streak_gap_avg_ms]=0
      if (( GR_PACE[streak_gaps] > 0 )); then
        GR_PACE[prev_streak_gap_avg_ms]=$((GR_PACE[streak_gap_sum_ms] / GR_PACE[streak_gaps]))
      fi
    fi
    GR_PACE[streak_kind]=$kind
    GR_PACE[streak_started_ms]=$GR_PACE_CLAIMED_MS
    GR_PACE[streak_requests]=0
    GR_PACE[streak_gaps]=0
    GR_PACE[streak_gap_min_ms]=0
    GR_PACE[streak_gap_max_ms]=0
    GR_PACE[streak_gap_sum_ms]=0
  fi
  GR_PACE[streak_requests]=$((GR_PACE[streak_requests] + 1))
  GR_PACE[streak_last_ms]=$GR_PACE_CLAIMED_MS
  if [[ -n "$GR_PACE_GAP_MS" ]]; then
    local gap=$GR_PACE_GAP_MS
    if (( GR_PACE[streak_gaps] == 0 || gap < GR_PACE[streak_gap_min_ms] )); then
      GR_PACE[streak_gap_min_ms]=$gap
    fi
    if (( gap > GR_PACE[streak_gap_max_ms] )); then
      GR_PACE[streak_gap_max_ms]=$gap
    fi
    GR_PACE[streak_gaps]=$((GR_PACE[streak_gaps] + 1))
    GR_PACE[streak_gap_sum_ms]=$((GR_PACE[streak_gap_sum_ms] + gap))
  fi
}

# Diagnostics only: appends the just-recorded response to gr::pace_log_file
# (columns: see CLAUDE.md). Must run under the pacing lock.
gr::pace_log() {
  local outcome="$1" cooldown_s="$2" note="${3:-}"
  local log; log="$(gr::pace_log_file)"
  if [[ -f "$log" ]] && (( $(stat -c %s "$log") >= GR_PACE_LOG_MAX_BYTES )); then
    mv -f "$log" "$log.1"
  fi
  if [[ ! -f "$log" ]]; then
    printf 'time\trequest_ms\tpid\tfirst\toutcome\tgap_ms\tinterval_ms\tcooldown_s\tstreak\tnote\n' > "$log"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$GR_PACE_CLAIMED_MS" "$$" "$GR_PACE_FIRST" \
    "$outcome" "${GR_PACE_GAP_MS:--}" "$GR_PACE_INTERVAL_MS" "$cooldown_s" \
    "${GR_PACE[streak_kind]}:${GR_PACE[streak_requests]}" "$note" >> "$log"
}

# Under the lock: records response $1 (ok|challenge, $2 = description).
# A response to a request started before the last challenge is stale and
# changes nothing. Sets GR_PACE_GIVE_UP=1 after max failed probes.
gr::pace_record() {
  local outcome="$1" note="${2:-}"
  gr::pace_settings
  gr::pace_load
  local now stale=0 cooldown_ms=0
  now="$(gr::now_ms)"
  GR_PACE_GIVE_UP=0
  if (( GR_PACE_CLAIMED_MS < GR_PACE[challenge_at] )); then
    stale=1
  fi

  if (( stale == 0 )); then
    case "$outcome" in
      ok)
        if (( GR_PACE[challenges] > 0 )); then
          if (( GR_PACE[incident_successes] == 0 )); then
            GR_PACE[incident_ok_since_ms]=$GR_PACE_CLAIMED_MS
          fi
          GR_PACE[incident_successes]=$((GR_PACE[incident_successes] + 1))
          if (( GR_PACE[incident_successes] >= GR_HTTP_PACE_INCIDENT_END_SUCCESSES
                && GR_PACE_CLAIMED_MS - GR_PACE[incident_ok_since_ms] >= GR_HTTP_PACE_INCIDENT_END_MS )); then
            local blocked=$((GR_PACE[incident_ok_since_ms] - GR_PACE[incident_started_ms]))
            if (( blocked < 0 )); then
              blocked=0
            fi
            note="incident ended: blocked $(gr::ms_to_s "$blocked")s, $((GR_PACE[challenges] - 1)) failed probe(s)"
            GR_PACE[challenges]=0
            GR_PACE[incident_successes]=0
          fi
        fi
        gr::pace_track_streak ok
        ;;
      challenge)
        if (( GR_PACE[challenges] == 0 )); then
          GR_PACE[incident_started_ms]=$GR_PACE_CLAIMED_MS
          cooldown_ms=$GR_PACE_PAUSE_MS
        else
          cooldown_ms=$(( (now - GR_PACE[incident_started_ms]) * GR_PACE_PROBE_PCT / 100 ))
          if (( cooldown_ms < GR_HTTP_PACE_PROBE_MIN_MS )); then
            cooldown_ms=$GR_HTTP_PACE_PROBE_MIN_MS
          fi
          # Failed probe no. GR_PACE[challenges]; the first challenge isn't one.
          if (( GR_PACE[challenges] >= GR_PACE_MAX_PROBES )); then
            # shellcheck disable=SC2034 # read by gr::http_get (http.sh)
            GR_PACE_GIVE_UP=1
          fi
        fi
        GR_PACE[incident_successes]=0
        GR_PACE[challenges]=$((GR_PACE[challenges] + 1))
        GR_PACE[challenge_at]=$now
        GR_PACE[note]="$note at $(date +%H:%M:%S)"
        if (( now + cooldown_ms > GR_PACE[cooldown_ms] )); then
          GR_PACE[cooldown_ms]=$((now + cooldown_ms))
        fi
        gr::pace_track_streak challenge
        ;;
    esac
  fi
  gr::pace_save
  if (( stale == 1 )); then
    outcome="stale-$outcome"
  fi
  gr::pace_log "$outcome" "$(gr::ms_to_s "$cooldown_ms")" "$note"
}

gr::pace_report() {
  gr::pace_locked gr::pace_record "$@"
}

# Blocks until the next request slot is due and claims it; re-checks the
# state after each sleep. Only challenge pauses are shown. $1 (URL) unused.
gr::throttle() {
  local shown=0
  while :; do
    gr::pace_locked gr::pace_claim
    (( GR_PACE_WAIT_MS > 0 )) || break
    if (( GR_PACE_WAIT_COOLDOWN == 1 )); then
      local what="bot-challenge pause"
      if (( GR_PACE[challenges] > 1 )); then
        what="bot-challenge probe $((GR_PACE[challenges] - 1))/$GR_PACE_MAX_PROBES failed"
      fi
      gr::term_status "waiting $(( (GR_PACE_WAIT_MS + 999) / 1000 ))s -- $what (${GR_PACE[note]:-challenge})"
      shown=1
    fi
    sleep "$(gr::ms_to_s "$GR_PACE_WAIT_MS")"
  done
  if (( shown == 1 )); then
    gr::term_clear_line
  fi
  # gr::term_clear_line fails off a terminal; don't leak that under set -e.
  return 0
}
