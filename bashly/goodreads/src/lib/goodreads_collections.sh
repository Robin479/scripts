# Collections: named, locally curated lists of books (e.g. "read", "prefs").
# Schema: {collection_id, title, books: [{book_id, added, pref?}]}, books
# kept sorted by numeric book_id.

gr::collection_dir() {
  echo "$(gr::data_dir)/collections"
}

gr::collection_file() {
  echo "$(gr::collection_dir)/$1.json"
}

# Prints collection $1's file path, or errors (return 1) if it doesn't exist.
gr::require_collection_file() {
  local id="$1"
  local file
  file="$(gr::collection_file "$id")"
  if [[ ! -f "$file" ]]; then
    echo "error: no collection $id" >&2
    return 1
  fi
  echo "$file"
}

# Normalizes a book reference to its numeric id: a bare id, '<id>-<slug>',
# '<id>.<Slug>', or a .../book/show/<id>... URL. Returns 1 if none found.
gr::parse_book_ref() {
  local ref="$1"
  ref="${ref##*/book/show/}"
  if [[ "$ref" =~ ^([0-9]+)([-._].*)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# Splits $1 on commas/whitespace and prints each book ref's id, one per line.
# Errors (return 1) on the first unparseable ref.
gr::parse_book_refs() {
  local refs ref id
  read -r -a refs <<< "${1//,/ }"
  for ref in "${refs[@]}"; do
    if ! id="$(gr::parse_book_ref "$ref")"; then
      echo "error: not a book id or goodreads book URL: $ref" >&2
      return 1
    fi
    echo "$id"
  done
}

# True if $1 is a valid preference value: a decimal number in [-1, 1].
gr::valid_pref() {
  local p="$1"
  [[ "$p" =~ ^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)$ ]] || return 1
  jq -en --argjson p "${p#+}" '$p >= -1 and $p <= 1' > /dev/null 2>&1
}

gr::create_collection() {
  local id="$1" title="$2"
  mkdir -p "$(gr::collection_dir)"
  jq -n -S \
    --arg id "$id" \
    --arg title "$title" \
    '{collection_id: $id, title: ($title | if . == "" then null else . end), books: []}' \
    > "$(gr::collection_file "$id")"
}

gr::update_collection_title() {
  local id="$1" title="$2"
  local file
  file="$(gr::require_collection_file "$id")" || return 1

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  jq -S --arg title "$title" '.title = ($title | if . == "" then null else . end)' "$file" > "$tmp_file" || return 1
  mv "$tmp_file" "$file"
}

# Upserts book $2. $3 = added date (YYYY-MM-DD), $4 = pref; for each, ""
# keeps an existing entry's value (a new entry gets today / no pref), and
# "-" (pref only) removes it. Prints "added" or "updated".
gr::add_collection_book() {
  local id="$1" book_id="$2" added="${3:-}" pref="${4:-}"
  local file
  file="$(gr::require_collection_file "$id")" || return 1

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  local outcome=added
  if jq -e --arg b "$book_id" 'any(.books[]?; .book_id == $b)' "$file" > /dev/null; then
    outcome=updated
  fi

  jq -S \
    --arg b "$book_id" \
    --arg added "$added" \
    --arg today "$(date +%Y-%m-%d)" \
    --arg pref "$pref" \
    '
      def apply:
        (if $added != "" then .added = $added else . end)
        | (if $pref == "-" then del(.pref)
           elif $pref != "" then .pref = ($pref | ltrimstr("+") | tonumber)
           else . end);
      if any(.books[]?; .book_id == $b) then
        .books |= map(if .book_id == $b then apply else . end)
      else
        .books += [{book_id: $b, added: $today} | apply]
      end
      | .books |= sort_by(.book_id | tonumber)
    ' "$file" > "$tmp_file" || return 1

  mv "$tmp_file" "$file"
  echo "$outcome"
}

# Returns 1 (nothing written) if the book isn't in the collection.
gr::remove_collection_book() {
  local id="$1" book_id="$2"
  local file
  file="$(gr::require_collection_file "$id")" || return 1

  if ! jq -e --arg b "$book_id" 'any(.books[]?; .book_id == $b)' "$file" > /dev/null; then
    return 1
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  jq -S --arg b "$book_id" '.books |= map(select(.book_id != $b))' "$file" > "$tmp_file" || return 1
  mv "$tmp_file" "$file"
}

gr::clear_collection_books() {
  local id="$1"
  local file
  file="$(gr::require_collection_file "$id")" || return 1

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  jq -S '.books = []' "$file" > "$tmp_file" || return 1
  mv "$tmp_file" "$file"
}
