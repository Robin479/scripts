: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[collection_id]}"
json="${args[--json]:-}"

file="$(gr::require_collection_file "$id")" || exit 1

if [[ -n "$json" ]]; then
  cat "$file"
  exit 0
fi

jq -r '.title // "(untitled)"' "$file"

count="$(jq -r '.books | length' "$file")"
echo
echo "Books ($count):"
[[ "$count" -eq 0 ]] && exit 0

# Titles from the book cache where available (no fetching).
book_dir="$(gr::book_dir)"
jq -r '.books[] | [.book_id, .added, (.pref // "" | tostring)] | @tsv' "$file" \
  | while IFS=$'\t' read -r book_id added pref; do
      book_title="(not cached)"
      if [[ -f "$book_dir/$book_id.json" ]]; then
        book_title="$(jq -r "$GR_TITLE_JQ_DEFS"'(.title // .name // "(untitled)") | strip_tagline' "$book_dir/$book_id.json")"
      fi
      printf '%s\t%s\t%s\t%s\n' "$book_id" "$added" "${pref:--}" "$book_title"
    done \
  | { printf 'book_id\tadded\tpref\ttitle\n'; cat; } \
  | column -t -s $'\t' -R 1,3 | sed 's/^/  /'
