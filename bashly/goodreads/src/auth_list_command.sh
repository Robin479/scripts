accounts_dir="$(gr::data_dir)/accounts"
current="$(gr::current_account)"

if [[ ! -d "$accounts_dir" ]] || [[ -z "$(ls -A "$accounts_dir" 2>/dev/null)" ]]; then
  echo "No accounts yet. Run 'goodreads auth import <cookie-file>' to add one."
  exit 0
fi

for dir in "$accounts_dir"/*/; do
  id="$(basename "$dir")"
  username="$(jq -r '.username // "?"' "$dir/profile.json" 2>/dev/null)" || username="?"
  marker=" "
  [[ "$id" == "$current" ]] && marker="*"
  echo "$marker $id  $username"
done
