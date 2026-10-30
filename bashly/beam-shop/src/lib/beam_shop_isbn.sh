# ISBN extraction and sanity checks for product detail pages. See CLAUDE.md
# "ISBN" (site quirks) and "product backfill-isbn".

# Issue codes that mean the page isn't the expected product at all -- its
# ISBN must not be stored.
readonly BS_ISBN_FATAL_ISSUES='["not-a-product-page","ordernumber-mismatch"]'

# jq helpers: normalization and ISBN-10/13 checksums.
# shellcheck disable=SC2016 # jq source, not bash vars
readonly BS_ISBN_JQ_DEFS='
  def isbn_norm: gsub("[^0-9Xx]"; "") | ascii_upcase;
  def isbn13_ok: test("^[0-9]{13}$")
    and ([explode[] - 48] as $d | [range(13) | $d[.] * (if . % 2 == 0 then 1 else 3 end)] | add % 10 == 0);
  def isbn10_ok: test("^[0-9]{9}[0-9X]$")
    and ([explode[] | if . == 88 then 10 else . - 48 end] as $d | [range(10) | $d[.] * (10 - .)] | add % 11 == 0);
'

bs::isbn_anomalies_dir() {
  local dir; dir="$(bs::data_dir)/isbn-anomalies"
  mkdir -p "$dir"
  echo "$dir"
}

# Raw facts from a product detail page (html file $1): title, subtitle,
# image_url, page_url (canonical), ordernumber (details table), every place
# an ISBN could show up, and the page's visible text -- minus other
# products' boxes (recommendation sliders), which carry their own ISBNs.
bs::extract_product_detail() {
  local html_file="$1"
  # shellcheck disable=SC2016 # xidel xquery, not bash vars
  xidel -s "$html_file" --extract-kind=xquery3 -e '
    let $doc := /,
        $entry := function($label) {
      $doc//span[@class="entryText"][normalize-space(.) = $label]/following-sibling::span[@class="entryTextAdditional"]
    }
    return {
      "title": normalize-space(string((//meta[@property="og:title"])[1]/@content)),
      "subtitle": normalize-space(string((//header[contains(concat(" ", normalize-space(@class), " "), " product--header ")]/following-sibling::h2[contains(concat(" ", normalize-space(@class), " "), " subtitle ")])[1])),
      "image_url": string((//meta[@property="og:image"])[1]/@content),
      "page_url": string((//link[@rel="canonical"])[1]/@href),
      "ordernumber": normalize-space(string($entry("Artikelnummer")[1])),
      "gtin13": [//meta[@itemprop="gtin13"]/normalize-space(@content)],
      "isbn_row": [$entry("ISBN")/normalize-space(.)],
      "other_meta": [//*[@itemprop = ("isbn", "gtin", "gtin8", "gtin12", "gtin14")]/normalize-space((@content, .)[1])],
      "reading_sample_ean": [//@data-reading_sample_ean/normalize-space(.)],
      "text": string-join(//body//text()[not(ancestor::script or ancestor::style
        or ancestor::*[contains(concat(" ", normalize-space(@class), " "), " product--box ")])], " ")
    }
  ' --output-format=json-wrapped 2> /dev/null | jq -c '.[0]'
}

# Turns bs::extract_product_detail's raw facts (stdin) into {title, subtitle,
# image_url, page_url, ordernumber, isbn, isbn_issues, isbn_sources}. isbn:
# the gtin13 meta, else the "ISBN" table row ("" if neither, or if a fatal
# issue says this isn't product $1's page; $1 "" skips that check).
bs::assess_product_detail() {
  local product_id="$1"
  jq -c --arg pid "$product_id" --argjson fatal "$BS_ISBN_FATAL_ISSUES" "$BS_ISBN_JQ_DEFS"'
    ({
      gtin13: .gtin13,
      isbn_row: .isbn_row,
      other_meta: .other_meta,
      reading_sample_ean: .reading_sample_ean,
      text: ([.text | scan("(?<![0-9A-Za-z])97[89](?:[- ]?[0-9]){10}(?![0-9])")]
        + [.text | scan("(?i)isbn(?:-1[03])?\\s*:?\\s*((?:[0-9][- ]?){9}[0-9X])(?![0-9X])") | .[0]])
    } | map_values(map(isbn_norm) | map(select(. != "")) | unique)) as $sources
    | ([$sources[][]] | unique) as $all
    | (($sources.gtin13 + $sources.isbn_row)[0] // "") as $pick
    | (.image_url | sub("^.*/"; "") | sub("\\.[^.]*$"; "")) as $cover_name
    | [
        (if .ordernumber == "" then "not-a-product-page" else empty end),
        (if $pid != "" and .ordernumber != "" and (.ordernumber | ltrimstr("SW")) != $pid then "ordernumber-mismatch" else empty end),
        (if ($all | length) == 0 then "no-isbn" else empty end),
        (if ($all | length) > 1 then "multiple-isbns" else empty end),
        (if ($all | length) > 0 and ($sources.gtin13 | length) == 0 then "gtin13-meta-missing" else empty end),
        (if ($all | length) > 0 and ($sources.isbn_row | length) == 0 then "isbn-row-missing" else empty end),
        (if any($all[]; length == 10) then "isbn10" else empty end),
        (if any($all[]; length != 10 and length != 13) then "bad-length" else empty end),
        (if any($all[]; length == 13 and (test("^97[89]") | not)) then "non-isbn-prefix" else empty end),
        (if any($all[]; (length == 13 and (isbn13_ok | not)) or (length == 10 and (isbn10_ok | not))) then "bad-checksum" else empty end),
        (if $pick != "" and ($cover_name | test("^([0-9]{13}|[0-9]{9}[0-9X])$")) and $cover_name != $pick then "cover-filename-differs" else empty end)
      ] as $issues
    | {
        title, subtitle, image_url, page_url, ordernumber,
        isbn: (if any($issues[]; IN($fatal[])) then "" else $pick end),
        isbn_issues: $issues,
        isbn_sources: $sources
      }
  '
}

# Keeps product $1's detail page (html file $3, fetched from $2) and its
# assessment ($4) under isbn-anomalies/ if it has ISBN issues, else removes
# any earlier record there.
bs::record_isbn_anomaly() {
  local product_id="$1" url="$2" html_file="$3" detail="$4"
  local dir; dir="$(bs::isbn_anomalies_dir)"
  if [[ "$(jq '.isbn_issues | length' <<< "$detail")" -eq 0 ]]; then
    rm -f "$dir/$product_id.json" "$dir/$product_id.html"
    return 0
  fi
  local content
  content="$(jq --arg pid "$product_id" --arg url "$url" \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{product_id: $pid, fetched_url: $url, checked_at: $checked_at} + .' <<< "$detail")" || return 1
  bs::write_file "$dir/$product_id.json" "$content"
  cat -- "$html_file" > "$dir/$product_id.html"
}

# Re-fetches product $1's detail page (via the shop search, which redirects
# straight to it -- the product record keeps no page url) and stores its
# isbn (null if the page has none). Prints the stored isbn ("none" if null);
# fails without touching the record if the page isn't product $1's.
bs::backfill_isbn() {
  local product_id="$1"
  local product_file; product_file="$(bs::product_file "$product_id")"
  [[ -f "$product_file" ]] || {
    echo "error: unknown product $product_id" >&2
    return 1
  }

  local term="$product_id"
  [[ "$product_id" =~ ^[0-9] ]] && term="SW$product_id"
  local url="${BS_BASE_URL}/search?sSearch=${term}"

  local detail
  detail="$(bs::fetch_product_detail "$url" "$product_id")" || {
    echo "error: product $product_id: could not fetch $url" >&2
    return 1
  }
  local fatal
  fatal="$(jq -r --argjson fatal "$BS_ISBN_FATAL_ISSUES" '[.isbn_issues[] | select(IN($fatal[]))] | join(", ")' <<< "$detail")"
  if [[ -n "$fatal" ]]; then
    echo "error: product $product_id: $fatal ($url) -- kept in isbn-anomalies/, record unchanged" >&2
    return 1
  fi

  local isbn; isbn="$(jq -r '.isbn' <<< "$detail")"
  local content
  content="$(jq --arg isbn "$isbn" \
    '({product_id, title, subtitle, isbn: null} + .) | .isbn = (if $isbn == "" then null else $isbn end)' \
    "$product_file")" || {
    echo "error: could not update product record for $product_id" >&2
    return 1
  }
  bs::write_file "$product_file" "$content"
  echo "${isbn:-none}"
}

# Summary of every isbn-anomalies/ record: a count per issue code, then one
# line per product (id, issues, stored isbn, title).
bs::isbn_anomaly_report() {
  local dir; dir="$(bs::isbn_anomalies_dir)"
  local -a files=("$dir"/*.json)
  if [[ ! -e "${files[0]}" ]]; then
    echo "No ISBN anomalies on record."
    return 0
  fi
  echo "${#files[@]} product(s) with ISBN anomalies:"
  jq -rs '[.[].isbn_issues[]] | group_by(.) | map("  \(length)\t\(.[0])") | .[]' "${files[@]}"
  echo
  jq -r '[.product_id, (.isbn_issues | join(",")), (if .isbn == "" then "-" else .isbn end), .title] | join("\t")' "${files[@]}"
  echo
  echo "Pages and full details: $dir/<product_id>.{html,json}"
}
