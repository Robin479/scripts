: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
all="${args[--all]:-}"
keys="${args[key]:-}"

if [[ -n "$all" && -n "$keys" ]]; then
  echo "error: --all and specific keys are mutually exclusive" >&2
  exit 1
fi

if [[ -z "$all" && -z "$keys" ]]; then
  echo "error: give one or more setting names, or --all" >&2
  exit 1
fi

if [[ -n "$all" ]]; then
  # shellcheck disable=SC2207 # bs::config_keys' own output is a plain newline-separated list, one key per line, none of them containing whitespace
  set_keys=($(bs::config_keys))
  if [[ "${#set_keys[@]}" -eq 0 ]]; then
    echo "No settings are currently set."
    exit 0
  fi
  keys="${set_keys[*]}"
fi

ok=0
# shellcheck disable=SC2086 # word-splitting is exactly what's wanted — keys is either bashly's own space-separated repeatable-arg string, or built the same way just above for --all
for key in $keys; do
  bs::config_del "$key"
  echo "$key -> unset (reverts to its default, if any)"
  ok=$((ok + 1))
done

echo "Unset $ok setting(s)."
