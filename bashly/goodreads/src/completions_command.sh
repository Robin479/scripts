send_completions

# send_completions (lib/send_completions.sh) is bashly-generated/vendored,
# never hand-edited -- this file isn't, so it's the place for a small
# override: bashly's own candidate lists include both a command's long
# form and its short alias (e.g. "list"/"ls") as equal words, so a bare
# TAB lists both -- per explicit direction, only the long form should
# show there; the short form should only appear once it's actually needed
# to disambiguate. Re-registers completion with a wrapper that runs the
# real `_goodreads_completions` first, then drops a short form from
# COMPREPLY whenever its long form also made that same result.
cat <<'EOF'

_goodreads_alias_pairs=("list:ls" "create:new" "remove:rm")

_goodreads_completions_filtered() {
  _goodreads_completions
  local pair long short w keep filtered
  for pair in "${_goodreads_alias_pairs[@]}"; do
    long="${pair%%:*}"
    short="${pair#*:}"
    keep=1
    for w in "${COMPREPLY[@]}"; do
      [[ "$w" == "$long" ]] && { keep=0; break; }
    done
    if [[ "$keep" -eq 0 ]]; then
      filtered=()
      for w in "${COMPREPLY[@]}"; do
        [[ "$w" == "$short" ]] || filtered+=("$w")
      done
      COMPREPLY=("${filtered[@]}")
    fi
  done
}
complete -F _goodreads_completions_filtered goodreads
EOF
