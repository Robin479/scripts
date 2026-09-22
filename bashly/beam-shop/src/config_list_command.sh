{
  printf 'key\tvalue\tdescription\n'
  for key in "${BS_CONFIG_KEYS[@]}"; do
    value="$(bs::config_get "$key" "")"
    if [[ -z "$value" ]]; then
      value="(default: $(bs::config_default_display "$key"))"
    fi
    printf '%s\t%s\t%s\n' "$key" "$value" "$(bs::config_describe "$key")"
  done
} | column -t -s $'\t'
