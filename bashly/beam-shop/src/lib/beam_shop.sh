readonly BS_BASE_URL="https://www.beam-shop.de"

bs::data_dir() {
  local dir="${args[--data-path]:-${BEAM_SHOP_DATA:-$HOME/.beam-shop}}"
  mkdir -p "$dir"
  echo "$dir"
}

# Plain redirect -- caller must pass already-produced, known-good content.
bs::write_file() {
  local file="$1" content="$2"
  printf '%s\n' "$content" > "$file"
}

bs::offline() {
  [[ -n "${args[--offline]:-}" ]]
}

bs::config_file() {
  echo "$(bs::data_dir)/config.ini"
}

bs::config_get() {
  # shellcheck disable=SC2034 # used by config.sh
  CONFIG_FILE="$(bs::config_file)"
  config_get "$@"
}

bs::config_set() {
  # shellcheck disable=SC2034 # used by config.sh
  CONFIG_FILE="$(bs::config_file)"
  config_set "$@"
}

bs::config_del() {
  # shellcheck disable=SC2034 # used by config.sh
  CONFIG_FILE="$(bs::config_file)"
  config_del "$@"
}

bs::config_keys() {
  # shellcheck disable=SC2034 # used by config.sh
  CONFIG_FILE="$(bs::config_file)"
  config_keys "$@"
}

# True if progress output should be quiet: $1 (--batch) given, or stderr isn't a terminal.
bs::fetch_quiet() {
  local batch_flag="$1"
  [[ -n "$batch_flag" ]] && return 0
  [[ -t 2 ]] && return 1
  return 0
}

# Self-updating status line to stderr; no-op if $2 is set.
bs::status_line() {
  local message="$1" quiet="$2"
  [[ -n "$quiet" ]] && return
  printf '\r\033[K%s' "$message" >&2
}

bs::status_line_clear() {
  local quiet="$1"
  [[ -n "$quiet" ]] || printf '\r\033[K' >&2
}

# Resolves a possibly-relative href against BS_BASE_URL.
bs::absolute_url() {
  local url="$1"
  if [[ "$url" == http* ]]; then
    echo "$url"
  else
    echo "${BS_BASE_URL}${url}"
  fi
}
