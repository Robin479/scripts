: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
blog_ids="${args[blog_id]:-}"
yes_flag="${args[--yes]:-}"
no_flag="${args[--no]:-}"
auto_flag="${args[--auto]:-}"

# Exactly one required — bashly doesn't enforce mutual exclusivity itself.
set_count=0
[[ -n "$yes_flag" ]] && set_count=$((set_count + 1))
[[ -n "$no_flag" ]] && set_count=$((set_count + 1))
[[ -n "$auto_flag" ]] && set_count=$((set_count + 1))

if [[ "$set_count" -ne 1 ]]; then
  echo "error: exactly one of --yes, --no, --auto is required" >&2
  exit 1
fi

if [[ -z "$blog_ids" ]]; then
  echo "error: give one or more blog ids" >&2
  exit 1
fi

# Merges onto the existing file rather than rebuilding it, so every other
# field is left untouched. --auto deletes the key (not null) — challenge is
# a true/false/absent tri-state.
mark_one() {
  local id="$1"
  local file
  file="$(gr::blog_file "$id")"

  if [[ ! -f "$file" ]]; then
    echo "$id -> not cached" >&2
    return 1
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  # Self-clearing: a RETURN trap is global, not scoped to this call.
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  if [[ -n "$auto_flag" ]]; then
    jq -S 'del(.challenge)' "$file" > "$tmp_file"
    echo "$id -> manual override cleared (falls back to the machine guess)"
  elif [[ -n "$yes_flag" ]]; then
    jq -S '. + {challenge: true}' "$file" > "$tmp_file"
    echo "$id -> marked as a challenge listing"
  else
    jq -S '. + {challenge: false}' "$file" > "$tmp_file"
    echo "$id -> marked as NOT a challenge listing"
  fi

  mv "$tmp_file" "$file"
}

ok=0
fail=0
# shellcheck disable=SC2086 # word-splitting is exactly what's wanted — blog_ids is bashly's own space-separated repeatable-arg string
for id in $blog_ids; do
  if mark_one "$id"; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

if [[ "$fail" -gt 0 ]]; then
  echo "Marked $ok blog post(s), $fail not cached."
  exit 1
fi
echo "Marked $ok blog post(s)."
