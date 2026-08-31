gr::data_dir() {
  local dir="${args[--data-path]:-${GOODREADS_DATA:-$HOME/.goodreads}}"
  mkdir -p "$dir"
  echo "$dir"
}

gr::offline() {
  [[ -n "${args[--offline]:-}" ]]
}

gr::config_file() {
  echo "$(gr::data_dir)/config.ini"
}

# Thin wrappers around bashly's own config_get/config_set (from `bashly add
# config`, src/lib/config.sh + src/lib/ini.sh) that point CONFIG_FILE at our
# resolved data directory first. This has to happen per-call, not once via a
# hook: bashly's initialize() hook runs before argument parsing, so
# --data-path isn't available yet at that point — gr::data_dir only works
# once a command function is actually running.
gr::config_get() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(gr::config_file)"
  config_get "$@"
}

gr::config_set() {
  # shellcheck disable=SC2034 # CONFIG_FILE is config.sh's global, used there
  CONFIG_FILE="$(gr::config_file)"
  config_set "$@"
}
