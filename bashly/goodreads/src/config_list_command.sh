{
  printf 'key\tvalue\tdescription\n'
  for key in "${GR_CONFIG_KEYS[@]}"; do
    value="$(gr::config_get "$key" "")"
    if [[ -z "$value" ]]; then
      value="(default: $(gr::config_default_display "$key"))"
    fi
    printf '%s\t%s\t%s\n' "$key" "$value" "$(gr::config_describe "$key")"
  done
} | column -t -s $'\t'
