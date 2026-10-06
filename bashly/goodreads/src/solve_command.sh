: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
read_id="${args[--read]:-}"
no_read="${args[--no-read]:-}"
no_prefs="${args[--no-prefs]:-}"
reread_pref="${args[--reread-pref]}"
optimize="${args[--optimize]}"
max_size="${args[--max-size]:-}"
min_size="${args[--min-size]:-}"
size="${args[--size]:-}"
top="${args[--top]}"
alternatives="${args[--alternatives]:-}"
json="${args[--json]:-}"

blog_specs=()
challenge_ids=()
prefs_ids=()
pref_specs=()
# bashly joins repeated values %q-escaped; eval re-splits them.
[[ -n "${args[--blog]:-}" ]] && eval "blog_specs=(${args[--blog]})"
[[ -n "${args[--challenge]:-}" ]] && eval "challenge_ids=(${args[--challenge]})"
# The positional challenge id is shorthand for --challenge.
[[ -n "${args[challenge_id]:-}" ]] && challenge_ids=("${args[challenge_id]}" "${challenge_ids[@]}")
[[ -n "${args[--prefs]:-}" ]] && eval "prefs_ids=(${args[--prefs]})"
[[ -n "${args[--pref]:-}" ]] && eval "pref_specs=(${args[--pref]})"

# Validate numeric options up front.
for opt in top alternatives; do
  [[ "$opt" == alternatives && -z "$alternatives" ]] && continue
  [[ "$opt" == top && "$top" == all ]] && continue
  if ! [[ "${!opt}" =~ ^[1-9][0-9]*$ ]]; then
    hint=""
    [[ "$opt" == top ]] && hint=" or 'all'"
    echo "error: --$opt must be a positive integer${hint}: ${!opt}" >&2
    exit 1
  fi
done
for opt in max-size min-size size; do
  var="${opt//-/_}"
  if [[ -n "${!var}" ]] && ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
    echo "error: --$opt must be a non-negative integer: ${!var}" >&2
    exit 1
  fi
done
# --size n = --min-size n --max-size n, strictly (no fallback to larger ones).
strict=""
if [[ -n "$size" ]]; then
  if [[ -n "$min_size" || -n "$max_size" ]]; then
    echo "error: --size can't be combined with --min-size/--max-size" >&2
    exit 1
  fi
  min_size="$size"
  max_size="$size"
  strict=1
fi
if [[ -n "$min_size" && -n "$max_size" ]] && (( min_size > max_size )); then
  echo "error: --min-size ($min_size) is larger than --max-size ($max_size)" >&2
  exit 1
fi
min_size="${min_size:-0}"
# --optimize: criteria compared in order, then the remaining ones as tie-breakers.
criteria=()
IFS=',' read -r -a optimize_specs <<< "$optimize"
for c in "${optimize_specs[@]}"; do
  if [[ ! "$c" =~ ^(count|pages|rating)$ ]]; then
    echo "error: --optimize takes a comma-separated list of count, pages, rating: $optimize" >&2
    exit 1
  fi
  if [[ " ${criteria[*]} " == *" $c "* ]]; then
    echo "error: --optimize lists $c twice: $optimize" >&2
    exit 1
  fi
  criteria+=("$c")
done
if [[ "${#criteria[@]}" -eq 0 ]]; then
  echo "error: --optimize needs at least one of count, pages, rating" >&2
  exit 1
fi
for c in count rating pages; do
  [[ " ${criteria[*]} " == *" $c "* ]] || criteria+=("$c")
done
criteria_json="$(printf '%s\n' "${criteria[@]}" | jq -R . | jq -s -c .)"
criteria_label="$(IFS=','; echo "${criteria[*]}")"

if ! gr::valid_pref "$reread_pref"; then
  echo "error: --reread-pref must be a number from -1 to 1: $reread_pref" >&2
  exit 1
fi
if [[ -n "$read_id" && -n "$no_read" ]]; then
  echo "error: --read and --no-read are mutually exclusive" >&2
  exit 1
fi
if [[ "${#prefs_ids[@]}" -gt 0 && -n "$no_prefs" ]]; then
  echo "error: --prefs and --no-prefs are mutually exclusive" >&2
  exit 1
fi

explicit_prefs='{}'
for spec in "${pref_specs[@]}"; do
  ref="${spec%=*}"
  p="${spec##*=}"
  if [[ "$spec" != *=* ]] || ! book_id="$(gr::parse_book_ref "$ref")" || ! gr::valid_pref "$p"; then
    echo "error: --pref must be '<book id or URL>=<p>' with p from -1 to 1: $spec" >&2
    exit 1
  fi
  explicit_prefs="$(jq -c --arg b "$book_id" --argjson p "${p#+}" '.[$b] = $p' <<< "$explicit_prefs")"
done

# Lists: every challenge's blog posts (default challenge only without
# --challenge/--blog), plus any --blog; a shared post is one list.
if [[ "${#challenge_ids[@]}" -eq 0 && "${#blog_specs[@]}" -eq 0 ]]; then
  default_id="$(gr::default_challenge_id "$(date +%Y-%m-%d)")" || {
    echo "error: no challenges yet. Give --blog <blog_id>, or run 'goodreads challenges create'." >&2
    exit 1
  }
  challenge_ids=("$default_id")
fi

challenges='[]'
blog_entries='[]'
for cid in "${challenge_ids[@]}"; do
  jq -e --arg c "$cid" 'any(.[]; .challenge_id == $c)' <<< "$challenges" > /dev/null && continue
  challenge_file="$(gr::require_challenge_file "$cid")" || exit 1
  # `end` is a jq keyword: no {end} shorthand (see gr::create_challenge).
  challenges="$(jq -c --slurpfile c "$challenge_file" '. + [$c[0] | {challenge_id, title, start, end: .end, max_badge: ([.count_badges[]?.count] | max), badge: (.count_badges // [] | max_by(.count) // null)}]' <<< "$challenges")"
  blog_entries="$(jq -c --slurpfile c "$challenge_file" '
    reduce ($c[0] | .challenge_id as $cid | .blogs[]? | {id: .blog_id, name, challenges: [$cid]}) as $b (.;
      if any(.[]; .id == $b.id) then map(if .id == $b.id then .challenges += $b.challenges | .name //= $b.name else . end) else . + [$b] end)
  ' <<< "$blog_entries")"
  if [[ "$(jq -r --arg c "$cid" '[.[] | select(.challenges | index($c))] | length' <<< "$blog_entries")" -eq 0 ]]; then
    echo "warning: challenge $cid has no linked blog posts" >&2
  fi
done
for bid in "${blog_specs[@]}"; do
  blog_entries="$(jq -c --arg id "$bid" 'if any(.[]; .id == $id) then . else . + [{id: $id, name: null, challenges: []}] end' <<< "$blog_entries")"
done
if [[ "$(jq 'length' <<< "$blog_entries")" -eq 0 ]]; then
  echo "error: no lists to solve for" >&2
  exit 1
fi

lists='[]'
# \x1f, not a tab: IFS whitespace would collapse an empty name field.
while IFS=$'\x1f' read -r bid bname bchallenges; do
  blog="$(gr::blog_json "$bid")" || {
    echo "error: could not fetch blog post $bid" >&2
    exit 1
  }
  entry="$(jq -c --arg name "$bname" --argjson ch "$bchallenges" '{id: .blog_id, name: (if $name != "" then $name else .title end), url: "https://www.goodreads.com/blog/show/\(.blog_id)", challenges: $ch, books: ([.book_sections[]?.books[]?.book_id] | unique)}' <<< "$blog")"
  lists="$(jq -c --argjson e "$entry" '. + [$e]' <<< "$lists")"
done < <(jq -r '.[] | [.id, (.name // ""), (.challenges | tojson)] | join("\u001f")' <<< "$blog_entries")

# Read books and preferences, from collections (defaults only if they exist).
read='[]'
if [[ -z "$no_read" ]]; then
  if [[ -n "$read_id" ]]; then
    read_file="$(gr::require_collection_file "$read_id")" || exit 1
  else
    read_file="$(gr::collection_file read)"
  fi
  [[ -f "$read_file" ]] && read="$(jq -c '[.books[] | {book_id, added}]' "$read_file")"
fi

prefs_files=()
if [[ -z "$no_prefs" ]]; then
  if [[ "${#prefs_ids[@]}" -gt 0 ]]; then
    for pid in "${prefs_ids[@]}"; do
      prefs_file="$(gr::require_collection_file "$pid")" || exit 1
      prefs_files+=("$prefs_file")
    done
  elif [[ -f "$(gr::collection_file prefs)" ]]; then
    prefs_files+=("$(gr::collection_file prefs)")
  fi
fi
prefs="$explicit_prefs"
if [[ "${#prefs_files[@]}" -gt 0 ]]; then
  prefs="$(jq -n -c --argjson explicit "$explicit_prefs" 'reduce (inputs | .books[] | select(.pref != null)) as $b ({}; .[$b.book_id] = $b.pref) | . + $explicit' "${prefs_files[@]}")"
fi

# Book metadata (cache only) for work merging and page counts.
mapfile -t all_ids < <(jq -r '.[].books[]' <<< "$lists"; jq -r '.[].book_id' <<< "$read"; jq -r 'keys[]' <<< "$prefs")
list_ids_count="$(jq '[.[].books[]] | unique | length' <<< "$lists")"
meta="$(gr::solve_book_meta "${all_ids[@]}")"
missing="$({ echo "$lists"; echo "$meta"; } | jq -s '.[1] as $meta | [.[0][].books[]] | unique | map(select($meta[.] == null)) | length')"
if [[ "$missing" -gt 0 ]]; then
  fetch_hint="goodreads books fetch --challenge <id>"
  [[ "${#challenge_ids[@]}" -gt 0 ]] && fetch_hint="goodreads books fetch$(printf ' --challenge %s' "${challenge_ids[@]}")"
  echo "warning: $missing of $list_ids_count listed books aren't cached -- their editions can't be merged into works, and their page counts are unknown. Run '$fetch_hint' first." >&2
fi

prepared="$(
  {
    echo "$lists"; echo "$meta"; echo "$read"; echo "$prefs"; echo "$challenges"
  } | jq -s -c --argjson reread "${reread_pref#+}" '{
    lists: .[0], meta: .[1], read: .[2], prefs: .[3], challenges: .[4],
    reread_pref: $reread
  }' | gr::solve_prepare
)" || exit 1

# Default size: sum over challenges of (largest badge - read during it),
# minus pinned, plus one.
if [[ -z "$max_size" ]]; then
  max_size="$(jq -r '[.challenges[] | select(.max_badge != null)] as $c | if ($c | length) == 0 then .n else ([($c | map([.max_badge - .read_during, 0] | max) | add) - (.pinned | length), 0] | max) + 1 end' <<< "$prepared")"
fi

(( max_size < min_size )) && max_size="$min_size"

covers="$(gr::solve_covers "$prepared" "$max_size" "$strict")" || exit 1
covers="$(jq -c --argjson min "$min_size" '.min_size = $min | .covers |= map(select(length >= $min))' <<< "$covers")"

ranked="$(
  { echo "$prepared"; echo "$covers"; } \
    | jq -s -c --argjson crit "$criteria_json" --argjson top "$([[ "$top" == all ]] && echo null || echo "$top")" --argjson alt "${alternatives:-null}" '{prepared: .[0], covers: .[1], optimize: $crit, top: $top, alternatives: $alt}' \
    | gr::solve_rank
)" || exit 1

if [[ -n "$json" ]]; then
  { echo "$prepared"; echo "$covers"; echo "$ranked"; } | jq -s '.[0].works as $works | {
    lists: .[0].lists,
    done: [.[0].done[] | {work: ., book: $works[.]}],
    pinned: [.[0].pinned[] | {work: ., book: $works[.]}],
    max_size: .[1].max_size,
    solutions: [.[2][] | del(.groups) | .picks |= map(.best |= map(. + {book: $works[.work]}))]
  }'
  exit 0
fi

{ echo "$prepared"; echo "$covers"; echo "$ranked"; } | gr::solve_format "$criteria_label"
