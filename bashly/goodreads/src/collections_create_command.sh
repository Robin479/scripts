: # no-op, keeps the shellcheck directive below line-scoped
# shellcheck disable=SC2154 # args is bashly's global associative array
id="${args[collection_id]}"
title="${args[--title]:-}"
books_raw="${args[--books]:-}"
date_raw="${args[--date]:-}"
pref="${args[--pref]:-}"

if [[ "$id" == */* || -z "$id" ]]; then
  echo "error: collection id must be non-empty and must not contain '/': $id" >&2
  exit 1
fi
if [[ -f "$(gr::collection_file "$id")" ]]; then
  echo "error: collection $id already exists" >&2
  exit 1
fi

# Validate everything before creating anything.
added=""
if [[ -n "$date_raw" ]]; then
  added="$(date -d "$date_raw" +%Y-%m-%d 2>/dev/null)" || {
    echo "error: could not parse --date: $date_raw" >&2
    exit 1
  }
fi
if [[ -n "$pref" ]] && ! gr::valid_pref "$pref"; then
  echo "error: --pref must be a number from -1 to 1: $pref" >&2
  exit 1
fi
book_ids="$(gr::parse_book_refs "$books_raw")" || exit 1
if [[ -z "$book_ids" && ( -n "$added" || -n "$pref" ) ]]; then
  echo "warning: ignoring --date/--pref, because no --books were given" >&2
fi

gr::create_collection "$id" "$title"
echo "Created collection $id${title:+: $title}"

for book_id in $book_ids; do
  outcome="$(gr::add_collection_book "$id" "$book_id" "$added" "$pref")" || exit 1
  echo "$id -> book $book_id $outcome"
done
