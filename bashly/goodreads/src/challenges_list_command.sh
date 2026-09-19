: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
challenge_dir="$(gr::challenge_dir)"

if [[ ! -d "$challenge_dir" ]] || [[ -z "$(ls -A "$challenge_dir" 2>/dev/null)" ]]; then
  echo "No challenges yet. Run 'goodreads challenges create --title <title> --start <date> --end <date>' to add one."
  exit 0
fi

files=()
for file in "$challenge_dir"/*.json; do
  [[ -e "$file" ]] && files+=("$file")
done

today="$(date +%Y-%m-%d)"

# "$GR_CHALLENGE_STATUS_JQ_DEF"'...' concatenates into one jq argument —
# see GR_CHALLENGE_STATUS_JQ_DEF in lib/goodreads_challenges.sh.
lines="$(cat "${files[@]}" | jq -s -r --arg today "$today" "$GR_CHALLENGE_STATUS_JQ_DEF"'
  sort_by(.start)
  | .[] | [
      .challenge_id,
      .title,
      .start,
      .end,
      challenge_status($today),
      ((.blogs // []) | length | tostring),
      ((.count_badges // []) | length | tostring)
    ] | @tsv
')"

{
  printf 'id\ttitle\tstart\tend\tstatus\tblogs\tbadges\n'
  echo "$lines"
} | column -t -s $'\t' -R 1,6,7
