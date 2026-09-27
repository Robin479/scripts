: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
id_raw="${args[--id]:-}"
title_raw="${args[--title]:-}"
start_raw="${args[--start]:-}"
end_raw="${args[--end]:-}"

today="$(date +%Y-%m-%d)"

if [[ -n "$id_raw" ]]; then
  if [[ "$id_raw" == */* ]]; then
    echo "error: --id must not contain '/': $id_raw" >&2
    exit 1
  fi
  if [[ -f "$(gr::challenge_file "$id_raw")" ]]; then
    echo "error: challenge $id_raw already exists" >&2
    exit 1
  fi
fi

# --no-goals = --no-badges --no-blogs.
no_badges="${args[--no-badges]:-}"
no_blogs="${args[--no-blogs]:-}"
if [[ -n "${args[--no-goals]:-}" ]]; then
  no_badges=1
  no_blogs=1
fi

# `[[ -v args[...] ]]` tells "not given" from "given empty" (so no bashly
# `default:`, which would also replace an explicit `--badges ""`).
# Warns that no-flags $1/$2 are overridden by explicit $3/$4.
warn_superfluous_no_flag() {
  local no_flag="$1" no_goals_flag="$2" given_flag_a="$3" given_flag_b="$4"
  local ignored=()
  [[ -v args["$no_flag"] ]] && ignored+=("$no_flag")
  [[ -v args["$no_goals_flag"] ]] && ignored+=("$no_goals_flag")
  local given="$given_flag_a"
  [[ -v args["$given_flag_b"] ]] && given="$given_flag_b"
  local ignored_joined="${ignored[0]}"
  [[ "${#ignored[@]}" -eq 2 ]] && ignored_joined="${ignored[0]} and ${ignored[1]}"
  echo "warning: ignoring $ignored_joined, because $given was given explicitly" >&2
}

if [[ -v args[--badges] && -v args[--badge] ]]; then
  echo "error: --badges and --badge are mutually exclusive -- use one or the other" >&2
  exit 1
fi

if [[ -n "$no_badges" ]] && { [[ -v args[--badges] ]] || [[ -v args[--badge] ]]; }; then
  warn_superfluous_no_flag --no-badges --no-goals --badges --badge
fi

default_badges="2:Page-Turner,3:Speed Reader,5:Book Boss"

# Each spec is '<count>' or '<count>:<title>'; explicit badges beat $no_badges.
badge_specs=()
if [[ -v args[--badge] ]]; then
  # bashly joins repeated values %q-escaped; eval re-splits them, keeping spaces.
  eval "badge_specs=(${args[--badge]})"
elif [[ -v args[--badges] ]]; then
  badges_raw="${args[--badges]}"
  [[ -n "$badges_raw" ]] && IFS=',' read -r -a badge_specs <<<"$badges_raw"
elif [[ -n "$no_badges" ]]; then
  : # badge_specs stays empty
else
  IFS=',' read -r -a badge_specs <<<"$default_badges"
fi

# Validate counts before creating anything, so no half-set-up challenge.
badge_counts=()
badge_titles=()
for spec in "${badge_specs[@]}"; do
  count="${spec%%:*}"
  if [[ "$spec" == *:* ]]; then
    title="${spec#*:}"
  else
    title=""
  fi
  if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --badges/--badge entries must be '<count>' or '<count>:<title>' with a positive integer count: $spec" >&2
    exit 1
  fi
  badge_counts+=("$count")
  badge_titles+=("$title")
done

if [[ -v args[--blogs] && -v args[--blog] ]]; then
  echo "error: --blogs and --blog are mutually exclusive -- use one or the other" >&2
  exit 1
fi

if [[ -n "$no_blogs" ]] && { [[ -v args[--blogs] ]] || [[ -v args[--blog] ]]; }; then
  warn_superfluous_no_flag --no-blogs --no-goals --blogs --blog
fi

blogs_given=0
[[ -v args[--blogs] ]] && blogs_given=1
[[ -v args[--blog] ]] && blogs_given=1

if [[ -n "$start_raw" ]]; then
  start="$(date -d "$start_raw" +%Y-%m-%d 2>/dev/null)" || {
    echo "error: could not parse --start date: $start_raw" >&2
    exit 1
  }
else
  start="$(gr::default_challenge_start "$today")" || exit 1
fi

if [[ -n "$end_raw" ]]; then
  end="$(date -d "$end_raw" +%Y-%m-%d 2>/dev/null)" || {
    echo "error: could not parse --end date: $end_raw" >&2
    exit 1
  }
else
  end="$(gr::default_challenge_end "$start")"
fi

if [[ "$end" < "$start" ]]; then
  echo "error: --end ($end) is before --start ($start)" >&2
  exit 1
fi

if [[ -z "$start_raw" ]]; then
  overlaps="$(gr::challenges_overlapping "$start" "$end")"
  if [[ -n "$overlaps" ]]; then
    echo "error: auto-selected window ($start to $end) overlaps existing challenge(s):" >&2
    while IFS=$'\t' read -r o_id o_start o_end; do
      echo "  challenge $o_id: $o_start to $o_end" >&2
    done <<<"$overlaps"
    echo "Pass --start explicitly to force this window." >&2
    exit 1
  fi
fi

if [[ -n "$title_raw" ]]; then
  title="$title_raw"
else
  title="$(gr::default_challenge_title "$start" "$end")"
fi

# Needs start/end resolved (default blog window); explicit blogs beat $no_blogs.
blog_ids=()
blog_titles=()
if [[ "$blogs_given" -eq 1 ]]; then
  blog_specs=()
  if [[ -v args[--blog] ]]; then
    # Same %q/eval round-trip as --badge.
    eval "blog_specs=(${args[--blog]})"
  else
    blogs_raw="${args[--blogs]}"
    [[ -n "$blogs_raw" ]] && IFS=',' read -r -a blog_specs <<<"$blogs_raw"
  fi

  # Fetch each post (cached or remote) to validate it and default its title.
  for spec in "${blog_specs[@]}"; do
    blog_id="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
      blog_title="${spec#*:}"
    else
      blog_title=""
    fi

    blog_json="$(gr::blog_json "$blog_id")" || {
      echo "error: could not fetch blog post $blog_id" >&2
      exit 1
    }
    [[ -z "$blog_title" ]] && blog_title="$(jq -r '.title // empty' <<<"$blog_json")"

    blog_ids+=("$blog_id")
    blog_titles+=("$blog_title")
  done
elif [[ -n "$no_blogs" ]]; then
  : # blog_ids/blog_titles stay empty
else
  mapfile -t blog_ids < <(gr::default_challenge_blogs "$start" "$end" "$today")
  for blog_id in "${blog_ids[@]}"; do
    blog_json="$(gr::blog_json "$blog_id")" || {
      echo "error: could not fetch blog post $blog_id" >&2
      exit 1
    }
    blog_titles+=("$(jq -r '.title // empty' <<<"$blog_json")")
  done
fi

id="$(gr::create_challenge "$title" "$start" "$end" "$id_raw")"

for i in "${!badge_counts[@]}"; do
  gr::add_challenge_count_badge "$id" "${badge_counts[$i]}" "${badge_titles[$i]}" || exit 1
done

for i in "${!blog_ids[@]}"; do
  gr::add_challenge_blog "$id" "${blog_ids[$i]}" "${blog_titles[$i]}" || exit 1
done

echo "Created challenge $id: $title ($start to $end)"
if [[ "${#badge_counts[@]}" -gt 0 ]]; then
  printed_badges=()
  for i in "${!badge_counts[@]}"; do
    if [[ -n "${badge_titles[$i]}" ]]; then
      printed_badges+=("${badge_counts[$i]}:${badge_titles[$i]}")
    else
      printed_badges+=("${badge_counts[$i]}")
    fi
  done
  printed="$(IFS=', '; echo "${printed_badges[*]}")"
  echo "Book-count badges: $printed"
fi
if [[ "${#blog_ids[@]}" -gt 0 ]]; then
  printed_blogs=()
  for i in "${!blog_ids[@]}"; do
    if [[ -n "${blog_titles[$i]}" ]]; then
      printed_blogs+=("${blog_ids[$i]}:${blog_titles[$i]}")
    else
      printed_blogs+=("${blog_ids[$i]}")
    fi
  done
  printed="$(IFS=', '; echo "${printed_blogs[*]}")"
  echo "Linked blog posts: $printed"
fi
