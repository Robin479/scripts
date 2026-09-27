# Hitting-set solver (see CLAUDE.md "Solver"): jq stages, JSON in/out.
#   gr::solve_prepare   problem -> reduced problem (works, groups, cache key)
#   gr::solve_enumerate reduced problem + max size -> irredundant group covers
#   gr::solve_rank      reduced problem + covers + options -> ranked solutions
# Only covers are cached (gr::solve_covers); they depend only on the group
# signatures, so weights and preferences never invalidate them.

readonly GR_SOLVE_CACHE_VERSION=1
# gr::solve_estimate probes; gr::solve_warn_if_large thresholds (search
# nodes, jq manages ~10k/s; covers).
readonly GR_SOLVE_ESTIMATE_PROBES=200
readonly GR_SOLVE_WARN_NODES=100000
readonly GR_SOLVE_WARN_COVERS=50000
# Bayesian rating prior: this many virtual ratings at the problem's median.
readonly GR_SOLVE_RATING_PRIOR_COUNT=1000
# Options shown for a single-list pick without --alternatives (others: all).
readonly GR_SOLVE_SINGLE_LIST_ALTERNATIVES=10

gr::solver_cache_dir() {
  echo "$(gr::data_dir)/solver"
}

# Prints {book_id: {work, title, pages, rating, ratings}} for the given ids
# found in the book cache (never fetches).
gr::solve_book_meta() {
  local book_dir files=() id
  book_dir="$(gr::book_dir)"
  for id in "$@"; do
    [[ -f "$book_dir/$id.json" ]] && files+=("$book_dir/$id.json")
  done
  if [[ "${#files[@]}" -eq 0 ]]; then
    echo '{}'
    return 0
  fi
  jq -n -c '
    [inputs | {key: .book_id, value: {
      work: (.work.legacyId // null),
      title: (.title // .name),
      pages: .numberOfPages,
      rating: .aggregateRating.ratingValue,
      ratings: .aggregateRating.ratingCount
    }}] | from_entries
  ' "${files[@]}"
}

# Input: {lists: [{id, name, url?, challenges: [challenge_id], books: [book_id]}],
# meta: gr::solve_book_meta, read: [{book_id, added}], prefs: {book_id: p},
# challenges: [{challenge_id, title, start, end, max_badge, badge}],
# reread_pref}.
#
# Books become works (w<work id>, or b<book id> uncached); lists are sorted
# canonically. Read during a challenge covers that challenge's (and
# challenge-less) lists; read before gets reread_pref unless prefs overrides.
# pref >= 1 pins a work, pref <= -1 excludes it.
gr::solve_prepare() {
  jq -c '
    . as $in
    | def wkey: ($in.meta[.].work) as $w | if $w == null then "b\(.)" else "w\($w)" end;

    # Canonical lists; identical ones are merged.
    ($in.lists
      | map(. + {works: (.books | map(wkey) | unique)})
      | group_by(.works)
      | map({ids: map(.id), names: map(.name), urls: map(.url // empty), challenges: (map(.challenges // [] | .[]) | unique), works: .[0].works})
      | sort_by([(.works | length), .works])
    ) as $lists

    # Editions per work, with the lists each appears in.
    | ([$in.lists[] | .id as $l | .books[] | {book_id: ., list: $l}]
       | group_by(.book_id)
       | map({book_id: .[0].book_id, work: (.[0].book_id | wkey), lists: (map(.list) | unique)})
       | group_by(.work)
       | map({key: .[0].work, value: map({book_id, lists})})
       | from_entries
    ) as $editions

    # Read books, relative to the challenge windows.
    | ($in.read | map(
        .added as $a
        | . + {work: (.book_id | wkey), during: [$in.challenges[] | select($a >= .start and $a <= .end) | .challenge_id]}
        | . + {when: (
            if (.during | length) > 0 then "during"
            elif ($in.challenges | length) == 0 or any($in.challenges[]; $a < .start) then "before"
            else "after" end
          )}
      )) as $read
    | ($read | map(select(.when == "during") | .work) | unique) as $done

    # Effective preference per work: reread default, then explicit prefs.
    | (($read | map(select(.when == "before") | {key: .work, value: $in.reread_pref}))
       + ($in.prefs | to_entries | map({key: (.key | wkey), value: .value}))
       | from_entries
    ) as $pref
    # Only works on some list matter; preferences may be global.
    | ([$lists[].works[]] | unique) as $listed
    | ($pref | to_entries | map(select(.value >= 1) | .key) - $done | . - (. - $listed)) as $pinned
    | ($pref | to_entries | map(select(.value <= -1) | .key) - $done | . - (. - $listed)) as $excluded

    | ($lists | map(
        . as $l
        # Read during one of the challenges of this list (any, if it has none).
        | ([$read[] | select(.when == "during")
            | select(($l.challenges | length) == 0 or any(.during[]; . as $c | $l.challenges | index($c)))
            | .work] | unique) as $done_here
        | ($l.works - ($l.works - $done_here)) as $done_by
        | ($l.works - ($l.works - $pinned)) as $pinned_by
        | ($l.works - $excluded) as $available
        | . + {done_by: $done_by, pinned_by: $pinned_by, available: $available, status: (
            if ($done_by | length) > 0 then "done"
            elif ($pinned_by | length) > 0 then "pinned"
            elif ($available | length) == 0 then "uncoverable"
            else "open" end
          )}
      )) as $lists
    | [$lists[] | select(.status == "open")] as $open

    # Signature groups over the open lists.
    | ([$open | to_entries[] | .key as $i | .value.available[] | {work: ., list: $i}]
       | group_by(.work)
       | map({work: .[0].work, sig: map(.list)})
       | group_by(.sig)
       | map({sig: .[0].sig, works: map(.work)})
       | sort_by(.sig)
    ) as $groups

    | ([$groups[].works[]] + $done + $pinned | unique) as $all_works
    | {
        lists: [$lists[] | {ids, names, urls, challenges, status, size: (.works | length), done_by, pinned_by}],
        open: [$open[] | .ids],
        open_urls: [$open[] | .urls],
        n: ($open | length),
        sigs: [$groups[].sig],
        groups: [$groups[].works],
        works: ($all_works | map(. as $wk | {key: $wk, value: (
          ($editions[$wk] // []) as $eds
          | ([$eds[].book_id] + [($read[] | .book_id), ($in.prefs | keys[])] | map(select(wkey == $wk)) | unique) as $bids
          | [$bids[] | $in.meta[.] // empty] as $metas
          | {
              title: ([$metas[].title | select(. != null)] | first // null),
              pages: ([$metas[].pages | select(. != null)] | first // null),
              rating: ([$metas[].rating | select(. != null)] | first // null),
              ratings: ([$metas[] | select(.rating != null) | .ratings] | first // null),
              book_id: ([$eds[].book_id] + $bids | first),
              pref: ($pref[$wk] // 0),
              editions: $eds
            }
        )}) | from_entries),
        done: $done,
        pinned: $pinned,
        excluded: $excluded,
        challenges: [$in.challenges[] | .challenge_id as $c | . + {read_during: ([$read[] | select(any(.during[]; . == $c))] | length)}]
      }
    | .key = ({v: '"$GR_SOLVE_CACHE_VERSION"', n, sigs} | tojson)
  '
}

# Input: gr::solve_prepare's output; $1 = max cover size. Prints {max_size,
# covers: [[group index]]}: every irredundant cover of at most $1 groups.
# Branches on the first uncovered list; siblings forbid the groups tried
# before them (each cover exactly once); prunes once a group turns redundant.
gr::solve_enumerate() {
  local max_size="$1"
  jq -c --argjson k "$max_size" '
    .n as $n | .sigs as $sigs
    | ([range(0; $n)] | map(. as $i | [$sigs | to_entries[] | select(.value | index($i)) | .key])) as $by
    | def rec($chosen; $cnt; $forbidden):
        ([range(0; $n) | select($cnt[.] == 0)] | first) as $u
        | if $u == null then $chosen
          elif ($chosen | length) >= $k then empty
          else
            $by[$u] as $cands
            | range(0; $cands | length) as $j
            | $cands[$j] as $g
            | select($forbidden[$g | tostring] | not)
            | (reduce $sigs[$g][] as $l ($cnt; .[$l] += 1)) as $cnt2
            | select([$chosen[], $g] | all(. as $h | $sigs[$h] | any(.[]; $cnt2[.] == 1)))
            | rec($chosen + [$g]; $cnt2; $forbidden + ($cands[0:$j] | map({key: tostring, value: true}) | from_entries))
          end;
    {max_size: $k, covers: [rec([]; [range(0; $n) | 0]; {}) | sort]}
  '
}

# Input: gr::solve_prepare's output; $1 = max cover size. Prints {nodes,
# covers}: Knuth's estimate of gr::solve_enumerate's tree size and result
# count (random probes, weighted by the product of their branching factors).
gr::solve_estimate() {
  local max_size="$1"
  # A file, not --argjson: probes * K numbers can exceed the argument size limit.
  jq -c --argjson k "$max_size" --argjson probes "$GR_SOLVE_ESTIMATE_PROBES" \
    --slurpfile seeds <(for (( i = 0; i < GR_SOLVE_ESTIMATE_PROBES * (max_size + 1); i++ )); do echo "$RANDOM"; done) '
    .n as $n | .sigs as $sigs | ($seeds | map(. / 32768)) as $seeds
    | ([range(0; $n)] | map(. as $i | [$sigs | to_entries[] | select(.value | index($i)) | .key])) as $by
    | def probe($p):
        {chosen: [], cnt: [range(0; $n) | 0], forb: {}, w: 1, nodes: 1, covers: 0, done: false}
        | until(.done;
            . as $s
            | ([range(0; $n) | select($s.cnt[.] == 0)] | first) as $u
            | if $u == null then .covers = .w | .done = true
              elif (.chosen | length) >= $k then .done = true
              else
                $by[$u] as $cands
                | [range(0; $cands | length) as $j | $cands[$j] as $g
                    | select($s.forb[$g | tostring] | not)
                    | (reduce $sigs[$g][] as $l ($s.cnt; .[$l] += 1)) as $cnt2
                    | select([$s.chosen[], $g] | all(. as $h | $sigs[$h] | any(.[]; $cnt2[.] == 1)))
                    | {chosen: ($s.chosen + [$g]), cnt: $cnt2, forb: ($s.forb + ($cands[0:$j] | map({key: tostring, value: true}) | from_entries))}
                  ] as $kids
                | if ($kids | length) == 0 then .done = true
                  else
                    $kids[$seeds[$p * ($k + 1) + ($s.chosen | length)] * ($kids | length) | floor] as $next
                    | .w *= ($kids | length) | .nodes += .w
                    | .chosen = $next.chosen | .cnt = $next.cnt | .forb = $next.forb
                  end
              end)
        | {nodes, covers};
    [range(0; $probes) | probe(.)]
    | {nodes: (map(.nodes) | add / length | round), covers: (map(.covers) | add / length | round)}
  '
}

# $1 = gr::solve_prepare's output, $2 = max cover size. Warns on stderr if
# gr::solve_estimate expects the enumeration to explode (it runs anyway).
gr::solve_warn_if_large() {
  local estimate nodes covers
  estimate="$(gr::solve_estimate "$2" <<< "$1")" || return 1
  nodes="$(jq -r '.nodes' <<< "$estimate")"
  covers="$(jq -r '.covers' <<< "$estimate")"
  if (( nodes > GR_SOLVE_WARN_NODES || covers > GR_SOLVE_WARN_COVERS )); then
    echo "warning: large search space (~$nodes steps, ~$covers solutions of up to $2 more book(s)) -- this may take very long. Consider a smaller --max-size, or recording books read." >&2
  fi
  return 0
}

# $1 = gr::solve_prepare's output, $2 = max cover size, $3 = strict. Prints
# {max_size, requested, covers}: covers of at most $2 groups, else (unless
# strict) the smallest ones there are; cached under gr::solver_cache_dir.
gr::solve_covers() {
  local prepared="$1" max_size="$2" strict="${3:-}"
  local n key cache_file cached_max requested="$max_size"
  n="$(jq -r '.n' <<< "$prepared")"
  (( max_size > n )) && max_size="$n"
  (( max_size < 0 )) && max_size=0
  key="$(jq -r '.key' <<< "$prepared" | sha256sum | cut -d' ' -f1)"
  cache_file="$(gr::solver_cache_dir)/$key.json"

  local result=""
  if [[ -f "$cache_file" ]]; then
    cached_max="$(jq -r '.max_size // -1' "$cache_file" 2>/dev/null || echo -1)"
    if (( cached_max >= max_size )); then
      result="$(jq -c . "$cache_file")" || result=""
    fi
  fi

  if [[ -z "$result" ]]; then
    gr::solve_warn_if_large "$prepared" "$max_size" || return 1
    result="$(gr::solve_enumerate "$max_size" <<< "$prepared")" || return 1
    # Nothing that small: every cover is <= n groups, so enumerate them all.
    if [[ -z "$strict" && "$(jq '.covers | length' <<< "$result")" -eq 0 ]] && (( max_size < n )); then
      max_size="$n"
      gr::solve_warn_if_large "$prepared" "$max_size" || return 1
      result="$(gr::solve_enumerate "$max_size" <<< "$prepared")" || return 1
    fi
    mkdir -p "$(gr::solver_cache_dir)"
    jq -c --argjson problem "$(jq -c '{n, sigs}' <<< "$prepared")" '. + $problem' <<< "$result" > "$cache_file.tmp" \
      && mv "$cache_file.tmp" "$cache_file"
  fi

  # A cache entry may cover more than asked for; keep what was asked, or
  # the smallest covers if nothing is that small.
  jq -c --argjson k "$max_size" --argjson requested "$requested" --arg strict "$strict" '
    (.covers | map(select(length <= $k))) as $small
    | if ($small | length) > 0 or $strict != "" or (.covers | length) == 0 then {max_size: $k, covers: $small}
      else (.covers | (map(length) | min) as $m | {max_size: $m, covers: map(select(length == $m))}) end
    | .requested = $requested
  ' <<< "$result"
}

# Input: {prepared, covers, optimize: [count|pages|rating], top: n | null,
# alternatives: n | null}. Per work, m = (1 - pref) / (1 + pref): count = m,
# pages = pages * m, rating = (5 - r') * m (r' Bayesian-shrunk); unknowns
# take the median. Groups pick their cheapest work; covers compare
# lexicographically by summed count/pages and mean rating.
gr::solve_rank() {
  jq -c --argjson prior "$GR_SOLVE_RATING_PRIOR_COUNT" --argjson single_alternatives "$GR_SOLVE_SINGLE_LIST_ALTERNATIVES" '
    .prepared as $p | .optimize as $crit | .top as $top | .alternatives as $alternatives
    | def median: sort | if length > 0 then .[length / 2 | floor] else null end;
    ([$p.works[] | .pages | select(. != null and . > 0)] | median // 300) as $median_pages
    | ([$p.works[] | .rating | select(. != null)] | median // 3.5) as $median_rating
    | def pages($w): $p.works[$w].pages | if . != null and . > 0 then . else $median_pages end;
    def adjusted($w): $p.works[$w] as $x
      | if $x.rating == null then $median_rating
        else ($x.ratings // 0) as $n | ($prior * $median_rating + $n * $x.rating) / ($prior + $n) end;
    def costs($w): $p.works[$w] as $x | ((1 - $x.pref) / (1 + $x.pref)) as $m
      | {count: $m, pages: (pages($w) * $m), rating: ((5 - adjusted($w)) * $m)};
    def vec: . as $c | [$crit[] | $c[.]];
    ($p.groups | map(map({work: ., costs: costs(.)}) | sort_by((.costs | vec), .work))) as $ranked
    | [.covers.covers[]
        | . as $groups
        | ([$groups[] | $ranked[.][0].work] + $p.pinned) as $books
        | ($books | map(costs(.))) as $c
        | {
            groups: $groups,
            books: ($books | length),
            more: ($groups | length),
            pages: ($books | map(pages(.)) | add // 0),
            rating: ([$books[] | $p.works[.].rating | select(. != null)] | if length > 0 then add / length else null end),
            key: ({
              count: ($c | map(.count) | add // 0),
              pages: ($c | map(.pages) | add // 0),
              rating: ($c | if length > 0 then (map(.rating) | add) / length else 0 end)
            } | vec)
          }
      ]
    | sort_by(.key)
    | .[:$top]
    | map(. + {picks: [.groups[] | {
        lists: [$p.sigs[.][] | $p.open[.][]],
        options: ($ranked[.] | length),
        best: $ranked[.][:($alternatives // (if ($p.sigs[.] | length) == 1 then $single_alternatives else null end))],
        sig: $p.sigs[.]
      }]})
  '
}

# Replaces "@@" marker lines by a rule as wide as the widest line (printable:
# column(1) drops control characters).
gr::solve_draw_separators() {
  local lines=() line width=0 rule
  mapfile -t lines
  for line in "${lines[@]}"; do
    (( ${#line} > width )) && width="${#line}"
  done
  printf -v rule '%*s' "$width" ''
  rule="${rule// /─}"
  for line in "${lines[@]}"; do
    if [[ "$line" == @@* ]]; then
      echo "$rule"
    else
      echo "$line"
    fi
  done
}

# Input (3 JSON documents): prepared, covers, ranked.
# $1 = the criteria ranked by (comma-separated). Prints the report.
gr::solve_format() {
  local optimize="$1"
  local report
  report="$(jq -s -c --arg opt "$optimize" '
    .[0] as $p | .[1] as $c | .[2] as $r
    | def cut($n): if length > $n then .[:$n - 1] + "…" else . end;
      def url: "https://www.goodreads.com/book/show/\(.)";
      # Rows of [{t, tag?}, pages, rating, pref, link]: one per edition if a
      # work has several; tag = "[<lists>]".
      def book($w): $p.works[$w] as $x
        | ($x.title // "(not cached)") as $t
        | [
            (if ($x.pages // 0) > 0 then "\($x.pages)p" else "?p" end),
            (if $x.rating != null then "\($x.rating)" else "" end),
            (if $x.pref != 0 then "pref \($x.pref)" else "" end)
          ] as $info
        | ($x.editions // []) as $eds
        | if ($eds | length) > 1 then
            [$eds[] | [{t: $t, tag: "[\(.lists | join(","))]"}] + $info + [(.book_id | url)]]
          else
            [[{t: $t}] + $info + [($x.book_id // ($w | ltrimstr("b")) | url)]]
          end;
      # Rows -> TSV lines; titles cut to $limit, tags right-aligned at the
      # widest title. ($limit, not $max: it would shadow the max builtin.)
      def table($limit):
        ([.[] | select(length > 1) | .[1]
          | if .tag then [(.t | length) + 1 + (.tag | length), $limit] | min else (.t | cut($limit) | length) end
         ] | max // 0) as $w
        | map(if length > 1 then
            .[1] |= (if .tag then
                ($w - (.tag | length) - 1) as $avail
                | (.t | cut($avail)) as $cut
                | $cut + (" " * ($avail - ($cut | length) + 1)) + .tag
              else .t | cut($limit) end)
            | @tsv
          else .[0] end);
      def ids: join("+");
      # max_size is capped at the open lists; a larger min_size shows the request.
      def range: (if (.min_size // 0) > .max_size then .requested else .max_size end) as $max
        | if (.min_size // 0) == 0 then "up to \($max)"
          elif .min_size == $max then "exactly \($max)"
          else "\(.min_size) to \($max)" end;
    {
      header: [
        (if ($p.challenges | length) == 0 then "Lists: " + ([$p.lists[].ids | ids] | join(", ")) else
          $p.challenges[] | "\(.title // "(untitled)") (\(.challenge_id)): \(.start) to \(.end) · read during it: \(.read_during)"
            + (if .max_badge != null then " · largest badge: \(.badge.name // "(unnamed)") (\(.max_badge))" else "" end)
        end),
        ([
          "pinned: \($p.pinned | length)",
          "excluded: \($p.excluded | length)",
          (if $c.max_size > $c.requested then "no solution with up to \($c.requested) more book(s), showing the smallest (\($c.max_size))"
           else "solving for \($c | range) more book(s)" end)
        ] | join(" · "))
      ],
      lists: [$p.lists[] | [
        (.ids | ids),
        ((.names | map(. // "(unnamed)") | join(" / ")) | cut(60)),
        (.size | tostring),
        (.urls | join(" ")),
        (if ($p.challenges | length) > 1 then (.challenges | join(",") | if . == "" then "-" else . end) else empty end),
        (.status + (
          if .status == "done" then ": " + (.done_by | map($p.works[.].title // .) | join(", "))
          elif .status == "pinned" then ": " + (.pinned_by | map($p.works[.].title // .) | join(", "))
          else "" end))
      ] | @tsv],
      summary: (if ($r | length) == 0 then
          (if $p.n == 0 then "Nothing left to solve: every list is done, pinned or uncoverable." else "No solutions with \($c | range) more book(s)." end)
        else "Solutions (best \($r | length) of \($c.covers | length) with \($c | range) more book(s), by \($opt)):" end),
      solutions: (([$p.pinned[] | book(.) | to_entries[] | [(if .key == 0 then "pinned" else "" end)] + .value]) as $pinned
      | [$r | to_entries[] | {
        # "more" = what the size options count; pinned books separately.
        title: ("#\(.key + 1)  \(.value.more) more book(s)" + (($p.pinned | length) as $n | if $n > 0 then " + \($n) pinned" else "" end) + ", \(.value.pages) pages" + (if .value.rating != null then ", \(.value.rating | . * 100 | round / 100) avg rating" else "" end)),
        # Pinned books, then one block per pick, "@@"-separated; a single-list
        # pick starts with its list link (any book on it will do).
        rows: (
          [(if ($pinned | length) > 0 then $pinned else empty end),
           (.value.picks[] | . as $pick | ($pick.sig | length == 1) as $single
            | (if $single then [$p.open_urls[$pick.sig[0]][] | [{t: "(any book on the list)"}, "", "", "", .]] else [] end) as $head
            | [$pick.best[] | book(.work)[]] as $books
            # Options cut off by --alternatives (or the single-list default).
            | ($pick.options - ($pick.best | length)) as $more
            | (if $more > 0 then [[{t: "(+\($more) more)"}, "", "", "", ""]] else [] end) as $tail
            | [$head + $books + $tail | to_entries[] | [(if .key == 0 then ($pick.lists | join(" ")) else "" end)] + .value])]
          | [.[] | ., [["@@"]]] | .[:-1] | add | table(50))
      }])
    }
  ')" || return 1

  jq -r '.header[]' <<< "$report"
  echo
  echo "Lists ($(jq '.lists | length' <<< "$report")):"
  jq -r '.lists[]' <<< "$report" | column -t -s $'\t' -R 3 | sed 's/^/  /'
  echo
  jq -r '.summary' <<< "$report"

  # One jq call for all solutions (--top all): NUL-terminated blocks of a
  # title line plus table rows.
  local block
  while IFS= read -r -d '' block; do
    echo
    echo "${block%%$'\n'*}"
    printf '%s\n' "${block#*$'\n'}" \
      | column -t -s $'\t' | sed 's/ *$//' | gr::solve_draw_separators | sed 's/^/  /'
  done < <(jq -j '.solutions[] | .title + "\n" + (.rows | join("\n")) + "\u0000"' <<< "$report")
}
