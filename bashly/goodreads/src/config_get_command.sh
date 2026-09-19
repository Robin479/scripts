: # keeps the shellcheck directive below scoped to one line, not file-wide (see CLAUDE.md)
# shellcheck disable=SC2154 # args is bashly's global associative array
key="${args[key]}"

value="$(gr::config_get "$key" "")"
if [[ -n "$value" ]]; then
  echo "$value"
else
  default="$(gr::config_default_display "$key")"
  if [[ -n "$default" ]]; then
    echo "$default (default)"
  else
    echo "(not set, no known default)"
  fi
fi
