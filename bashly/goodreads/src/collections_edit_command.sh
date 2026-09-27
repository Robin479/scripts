: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[collection_id]}"
date_raw="${args[--date]:-}"
pref="${args[--pref]:-}"

# `-v`, not `-n`: an explicit empty --title/--books means "clear it".
set_title=0
[[ -v args[--title] ]] && set_title=1
replace_books=0
[[ -v args[--books] ]] && replace_books=1

# bashly joins repeated values %q-escaped; eval re-splits them.
add_specs=()
remove_specs=()
[[ -n "${args[--add-book]:-}" ]] && eval "add_specs=(${args[--add-book]})"
[[ -n "${args[--remove-book]:-}" ]] && eval "remove_specs=(${args[--remove-book]})"

if [[ "$set_title" -eq 0 && "$replace_books" -eq 0 && "${#add_specs[@]}" -eq 0 && "${#remove_specs[@]}" -eq 0 ]]; then
  echo "error: give at least one of --title, --books, --add-book, --remove-book" >&2
  exit 1
fi

if [[ "$replace_books" -eq 1 ]] && [[ "${#add_specs[@]}" -gt 0 || "${#remove_specs[@]}" -gt 0 ]]; then
  echo "error: --books can't be combined with --add-book/--remove-book" >&2
  exit 1
fi

file="$(gr::require_collection_file "$id")" || exit 1

# Validate everything before writing anything.
added=""
if [[ -n "$date_raw" ]]; then
  added="$(date -d "$date_raw" +%Y-%m-%d 2>/dev/null)" || {
    echo "error: could not parse --date: $date_raw" >&2
    exit 1
  }
fi
if [[ -n "$pref" && "$pref" != "-" ]] && ! gr::valid_pref "$pref"; then
  echo "error: --pref must be a number from -1 to 1, or '-': $pref" >&2
  exit 1
fi

if [[ "$replace_books" -eq 1 ]]; then
  add_ids="$(gr::parse_book_refs "${args[--books]}")" || exit 1
else
  add_ids="$(gr::parse_book_refs "${add_specs[*]}")" || exit 1
fi
remove_ids="$(gr::parse_book_refs "${remove_specs[*]}")" || exit 1

if [[ -z "$add_ids" && ( -n "$added" || -n "$pref" ) ]]; then
  echo "warning: ignoring --date/--pref, because no --books/--add-book were given" >&2
fi

if [[ "$set_title" -eq 1 ]]; then
  gr::update_collection_title "$id" "${args[--title]}" || exit 1
  echo "$id -> title updated"
fi

if [[ "$replace_books" -eq 1 ]]; then
  # Keep existing entries' date/pref for books that stay in the collection.
  keep_json="$(jq -c '.books' "$file")"
  gr::clear_collection_books "$id" || exit 1
  echo "$id -> books cleared"
fi

for book_id in $add_ids; do
  book_added="$added"
  book_pref="$pref"
  if [[ "$replace_books" -eq 1 ]]; then
    [[ -z "$book_added" ]] && book_added="$(jq -r --arg b "$book_id" '.[] | select(.book_id == $b) | .added // empty' <<< "$keep_json")"
    [[ -z "$book_pref" ]] && book_pref="$(jq -r --arg b "$book_id" '.[] | select(.book_id == $b) | .pref // empty' <<< "$keep_json")"
  fi
  outcome="$(gr::add_collection_book "$id" "$book_id" "$book_added" "$book_pref")" || exit 1
  echo "$id -> book $book_id $outcome"
done

fail=0
if [[ -n "$remove_ids" ]]; then
  ok=0
  for book_id in $remove_ids; do
    if gr::remove_collection_book "$id" "$book_id"; then
      echo "$id -> book $book_id removed"
      ok=$((ok + 1))
    else
      echo "$id -> book $book_id not in this collection" >&2
      fail=$((fail + 1))
    fi
  done
  echo "Removed $ok book(s)."
fi

[[ "$fail" -gt 0 ]] && exit 1
exit 0
