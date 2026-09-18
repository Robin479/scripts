: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
book_ids="${args[book_id]:-}"
blog_ids="${args[--blog]:-}"

if [[ -n "$all" && ( -n "$book_ids" || -n "$blog_ids" ) ]]; then
  echo "error: --all and specific book ids (directly or via --blog) are mutually exclusive" >&2
  exit 1
fi

if [[ -z "$all" && -z "$book_ids" && -z "$blog_ids" ]]; then
  echo "error: give one or more book ids, --blog <blog_id>, or --all" >&2
  exit 1
fi

if [[ -n "$blog_ids" ]]; then
  # shellcheck disable=SC2086 # word-splitting is exactly what's wanted — blog_ids is bashly's own space-separated repeatable-flag string
  for blog_id in $blog_ids; do
    blog_json="$(gr::blog_json "$blog_id")" || {
      echo "error: could not fetch blog post $blog_id" >&2
      exit 1
    }
    blog_book_ids="$(jq -r '[.book_sections[]?.books[]?.book_id] | .[]' <<< "$blog_json")"
    if [[ -z "$blog_book_ids" ]]; then
      echo "note: blog post $blog_id has no books to extract" >&2
    fi
    book_ids="${book_ids} ${blog_book_ids}"
  done

  # Books can legitimately repeat across --blog posts, or overlap with an
  # explicitly given book_id — dedup so the same id isn't force-refreshed
  # more than once in this run.
  book_ids="$(tr -s ' ' '\n' <<< "$book_ids" | grep -v '^$' | sort -n -u | tr '\n' ' ')"
fi

if [[ -n "$all" ]]; then
  book_dir="$(gr::book_dir)"
  ids=()
  for file in "$book_dir"/*.json; do
    [[ -e "$file" ]] && ids+=("$(basename "$file" .json)")
  done
  if [[ "${#ids[@]}" -eq 0 ]]; then
    echo "No cached books yet."
    exit 0
  fi
  book_ids="${ids[*]}"
fi

ok=0
fail=0
# shellcheck disable=SC2086 # word-splitting is exactly what's wanted — book_ids is either bashly's own space-separated repeatable-arg string, or built the same way just above for --all
for id in $book_ids; do
  if gr::book_json "$id" --force > /dev/null; then
    echo "$id -> refreshed"
    ok=$((ok + 1))
  else
    echo "$id -> failed" >&2
    fail=$((fail + 1))
  fi
done

echo "Refreshed $ok book(s), $fail failed."
