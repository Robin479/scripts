: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
series_id="${args[series_id]}"

bs::require_series_file "$series_id" > /dev/null || exit 1

bs::print_series_matchers_table "$series_id"
