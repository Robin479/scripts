: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[challenge_id]}"
title="${args[--title]:-}"
start_raw="${args[--start]:-}"
end_raw="${args[--end]:-}"
add_blog_raw="${args[--add-blog]:-}"
remove_blog_ids="${args[--remove-blog]:-}"
add_badge_raw="${args[--add-badge]:-}"
remove_badge_raw="${args[--remove-badge]:-}"

if [[ -z "$title" && -z "$start_raw" && -z "$end_raw" \
      && -z "$add_blog_raw" && -z "$remove_blog_ids" \
      && -z "$add_badge_raw" && -z "$remove_badge_raw" ]]; then
  echo "error: give at least one of --title, --start, --end, --add-blog, --remove-blog, --add-badge, --remove-badge" >&2
  exit 1
fi

start=""
if [[ -n "$start_raw" ]]; then
  start="$(date -d "$start_raw" +%Y-%m-%d 2>/dev/null)" || {
    echo "error: could not parse --start date: $start_raw" >&2
    exit 1
  }
fi

end=""
if [[ -n "$end_raw" ]]; then
  end="$(date -d "$end_raw" +%Y-%m-%d 2>/dev/null)" || {
    echo "error: could not parse --end date: $end_raw" >&2
    exit 1
  }
fi

file="$(gr::require_challenge_file "$id")" || exit 1

# Validate the resulting window (whichever of the existing/updated
# start+end apply) before writing anything.
effective_start="${start:-$(jq -r '.start' "$file")}"
effective_end="${end:-$(jq -r '.end' "$file")}"
if [[ "$effective_end" < "$effective_start" ]]; then
  echo "error: end ($effective_end) would be before start ($effective_start)" >&2
  exit 1
fi

# Parse --add-blog specs ('<blog_id>' or '<blog_id>:<name>') up front.
add_blog_ids=()
add_blog_names=()
add_blog_specs=()
if [[ -n "$add_blog_raw" ]]; then
  # Same %q/eval round-trip `challenges create`'s own --blog/--badge need
  # -- a blog name can just as easily carry a space as a badge title can.
  eval "add_blog_specs=(${args[--add-blog]})"
  for spec in "${add_blog_specs[@]}"; do
    bid="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
      bname="${spec#*:}"
    else
      bname=""
    fi
    add_blog_ids+=("$bid")
    add_blog_names+=("$bname")
  done
fi

# Parse --add-badge specs ('<count>' or '<count>:<name>') up front,
# validating the count is a positive integer before writing anything --
# same as `challenges create`'s own --badge/--badges validation.
add_badge_counts=()
add_badge_names=()
add_badge_specs=()
if [[ -n "$add_badge_raw" ]]; then
  eval "add_badge_specs=(${args[--add-badge]})"
  for spec in "${add_badge_specs[@]}"; do
    bcount="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
      bname="${spec#*:}"
    else
      bname=""
    fi
    if ! [[ "$bcount" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: --add-badge entries must be '<count>' or '<count>:<name>' with a positive integer count: $spec" >&2
      exit 1
    fi
    add_badge_counts+=("$bcount")
    add_badge_names+=("$bname")
  done
fi

# Validate --remove-badge counts up front too -- a typo shouldn't leave
# some of this edit's other changes applied and others not.
remove_badge_counts=()
if [[ -n "$remove_badge_raw" ]]; then
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — remove_badge_raw is bashly's own space-separated repeatable-arg string
  for c in $remove_badge_raw; do
    if ! [[ "$c" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: --remove-badge must be a positive integer: $c" >&2
      exit 1
    fi
    remove_badge_counts+=("$c")
  done
fi

if [[ -n "$title" || -n "$start" || -n "$end" ]]; then
  gr::update_challenge "$id" "$title" "$start" "$end" || exit 1
  echo "$id -> updated"
fi

for i in "${!add_blog_ids[@]}"; do
  gr::add_challenge_blog "$id" "${add_blog_ids[$i]}" "${add_blog_names[$i]}" || exit 1
  if [[ -n "${add_blog_names[$i]}" ]]; then
    echo "$id -> blog ${add_blog_ids[$i]} added/updated (\"${add_blog_names[$i]}\")"
  else
    echo "$id -> blog ${add_blog_ids[$i]} added/updated"
  fi
done

for i in "${!add_badge_counts[@]}"; do
  gr::add_challenge_count_badge "$id" "${add_badge_counts[$i]}" "${add_badge_names[$i]}" || exit 1
  if [[ -n "${add_badge_names[$i]}" ]]; then
    echo "$id -> ${add_badge_counts[$i]}-book badge added/updated (\"${add_badge_names[$i]}\")"
  else
    echo "$id -> ${add_badge_counts[$i]}-book badge added/updated"
  fi
done

fail=0

if [[ -n "$remove_blog_ids" ]]; then
  ok=0
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — remove_blog_ids is bashly's own space-separated repeatable-arg string
  for bid in $remove_blog_ids; do
    if gr::remove_challenge_blog "$id" "$bid"; then
      echo "$id -> blog $bid removed"
      ok=$((ok + 1))
    else
      echo "$id -> blog $bid not on this challenge" >&2
      fail=$((fail + 1))
    fi
  done
  echo "Removed $ok blog(s)."
fi

if [[ "${#remove_badge_counts[@]}" -gt 0 ]]; then
  ok=0
  for c in "${remove_badge_counts[@]}"; do
    if gr::remove_challenge_count_badge "$id" "$c"; then
      echo "$id -> $c-book badge removed"
      ok=$((ok + 1))
    else
      echo "$id -> no $c-book badge on this challenge" >&2
      fail=$((fail + 1))
    fi
  done
  echo "Removed $ok badge(s)."
fi

[[ "$fail" -gt 0 ]] && exit 1
exit 0
