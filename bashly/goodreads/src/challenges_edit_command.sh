: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[challenge_id]}"
title="${args[--title]:-}"
start_raw="${args[--start]:-}"
end_raw="${args[--end]:-}"
add_blog_raw="${args[--add-blog]:-}"
remove_blog_ids="${args[--remove-blog]:-}"
add_badge_raw="${args[--add-badge]:-}"
remove_badge_raw="${args[--remove-badge]:-}"

# `-v`, not `-n`: an explicit empty --blogs/--badges means "clear the list".
replace_blogs=0
[[ -v args[--blogs] ]] && replace_blogs=1
replace_badges=0
[[ -v args[--badges] ]] && replace_badges=1

if [[ -z "$title" && -z "$start_raw" && -z "$end_raw" \
      && "$replace_blogs" -eq 0 && -z "$add_blog_raw" && -z "$remove_blog_ids" \
      && "$replace_badges" -eq 0 && -z "$add_badge_raw" && -z "$remove_badge_raw" ]]; then
  echo "error: give at least one of --title, --start, --end, --blogs, --add-blog, --remove-blog, --badges, --add-badge, --remove-badge" >&2
  exit 1
fi

# Replace plus incremental change of the same list is ambiguous -- refuse.
if [[ "$replace_blogs" -eq 1 ]] && [[ -n "$add_blog_raw" || -n "$remove_blog_ids" ]]; then
  echo "error: --blogs can't be combined with --add-blog/--remove-blog" >&2
  exit 1
fi
if [[ "$replace_badges" -eq 1 ]] && [[ -n "$add_badge_raw" || -n "$remove_badge_raw" ]]; then
  echo "error: --badges can't be combined with --add-badge/--remove-badge" >&2
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

# Validate the resulting start/end window before writing anything.
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
  # bashly joins repeated values %q-escaped; eval re-splits them, keeping spaces.
  eval "add_blog_specs=(${args[--add-blog]})"
  for spec in "${add_blog_specs[@]}"; do
    bid="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
      bname="${spec#*:}"
    else
      bname=""
    fi
    # Untitled: keep the current title, else the post's own (also validates it).
    blog_json="$(gr::blog_json "$bid")" || {
      echo "error: could not fetch blog post $bid" >&2
      exit 1
    }
    [[ -z "$bname" ]] && bname="$(jq -r --arg bid "$bid" '.blogs[]? | select(.blog_id == $bid) | .name // empty' "$file")"
    [[ -z "$bname" ]] && bname="$(jq -r '.title // empty' <<<"$blog_json")"
    add_blog_ids+=("$bid")
    add_blog_names+=("$bname")
  done
fi

# --blogs: into the same add_blog_* arrays (list is cleared first, below);
# each post is fetched to validate it. Untitled entries keep their current
# title, else the post's own.
if [[ "$replace_blogs" -eq 1 ]]; then
  blog_specs=()
  [[ -n "${args[--blogs]}" ]] && IFS=',' read -r -a blog_specs <<<"${args[--blogs]}"
  for spec in "${blog_specs[@]}"; do
    bid="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
      bname="${spec#*:}"
    else
      bname=""
    fi
    blog_json="$(gr::blog_json "$bid")" || {
      echo "error: could not fetch blog post $bid" >&2
      exit 1
    }
    [[ -z "$bname" ]] && bname="$(jq -r --arg bid "$bid" '.blogs[]? | select(.blog_id == $bid) | .name // empty' "$file")"
    [[ -z "$bname" ]] && bname="$(jq -r '.title // empty' <<<"$blog_json")"
    add_blog_ids+=("$bid")
    add_blog_names+=("$bname")
  done
fi

# Parse --add-badge specs ('<count>' or '<count>:<name>') up front.
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

# --badges: same, into the same arrays; untitled entries keep their current title.
if [[ "$replace_badges" -eq 1 ]]; then
  badge_specs=()
  [[ -n "${args[--badges]}" ]] && IFS=',' read -r -a badge_specs <<<"${args[--badges]}"
  for spec in "${badge_specs[@]}"; do
    bcount="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
      bname="${spec#*:}"
    else
      bname=""
    fi
    if ! [[ "$bcount" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: --badges entries must be '<count>' or '<count>:<title>' with a positive integer count: $spec" >&2
      exit 1
    fi
    [[ -z "$bname" ]] && bname="$(jq -r --argjson c "$bcount" '.count_badges[]? | select(.count == $c) | .name // empty' "$file")"
    add_badge_counts+=("$bcount")
    add_badge_names+=("$bname")
  done
fi

# Validate --remove-badge counts up front, so a typo can't half-apply the edit.
remove_badge_counts=()
if [[ -n "$remove_badge_raw" ]]; then
  # shellcheck disable=SC2086 # intentional word-splitting of bashly's repeatable arg
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

if [[ "$replace_blogs" -eq 1 ]]; then
  gr::clear_challenge_blogs "$id" || exit 1
  echo "$id -> blogs cleared"
fi

for i in "${!add_blog_ids[@]}"; do
  gr::add_challenge_blog "$id" "${add_blog_ids[$i]}" "${add_blog_names[$i]}" || exit 1
  if [[ -n "${add_blog_names[$i]}" ]]; then
    echo "$id -> blog ${add_blog_ids[$i]} added/updated (\"${add_blog_names[$i]}\")"
  else
    echo "$id -> blog ${add_blog_ids[$i]} added/updated"
  fi
done

if [[ "$replace_badges" -eq 1 ]]; then
  gr::clear_challenge_count_badges "$id" || exit 1
  echo "$id -> badges cleared"
fi

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
  # shellcheck disable=SC2086 # intentional word-splitting of bashly's repeatable arg
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
