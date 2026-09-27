: # no-op
collection_dir="$(gr::collection_dir)"

files=()
for file in "$collection_dir"/*.json; do
  [[ -e "$file" ]] && files+=("$file")
done

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No collections yet. Run 'goodreads collections create <id>' to add one."
  exit 0
fi

lines="$(cat "${files[@]}" | jq -s -r '
  sort_by(.collection_id)
  | .[] | [
      .collection_id,
      (.title // "(untitled)"),
      ((.books // []) | length | tostring),
      ((.books // []) | map(.added) | min // "-"),
      ((.books // []) | map(.added) | max // "-")
    ] | @tsv
')"

{
  printf 'id\ttitle\tbooks\tfirst added\tlast added\n'
  echo "$lines"
} | column -t -s $'\t' -R 3
