# Registry `config list`/`get`/`set` key off. Real defaults live at each bs::config_get call site.
readonly BS_CONFIG_KEYS=(
  curl_bin
  http_request_delay_min
  http_request_delay_max
  http_retry_delays
  discovery_root_url
  category_cache_ttl
  category_settle_period
  category_full_sync_max_interval
  category_full_sync_ramp
  image_width
  image_height
  image_format
  known_placeholder_hashes
)

bs::config_is_known_key() {
  local key="$1" k
  for k in "${BS_CONFIG_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

bs::config_describe() {
  case "$1" in
    curl_bin) echo "curl command to run for HTTP requests (auto-detected when unset)" ;;
    http_request_delay_min) echo "minimum delay, in seconds, enforced between requests" ;;
    http_request_delay_max) echo "maximum delay, in seconds, enforced between requests" ;;
    http_retry_delays) echo "comma-separated retry backoff delays, in seconds, for empty-body challenge responses" ;;
    discovery_root_url) echo "category page 'categories list' crawls from when no parent id is given" ;;
    category_cache_ttl) echo "seconds a category's own cached child-list stays fresh before 'categories list' re-crawls it (a new cycle/series can appear over time)" ;;
    category_settle_period) echo "seconds after a synced category's newest item during which refreshes still head-check it (page 1 until the first already-linked item); afterwards it's skipped until its next full walk is due" ;;
    category_full_sync_max_interval) echo "seconds between full walks of a synced category that hasn't gained anything for a long time -- the interval approaches this as (last full walk - newest item) grows" ;;
    category_full_sync_ramp) echo "seconds setting how fast the full-walk interval grows towards category_full_sync_max_interval: interval = max * (1 - e^(-(last full walk - newest item) / ramp))" ;;
    image_width) echo "target width, in pixels, for 'covers resize'" ;;
    image_height) echo "target height, in pixels, for 'covers resize'" ;;
    image_format) echo "target image format/extension for 'covers resize'" ;;
    known_placeholder_hashes) echo "comma-separated sha256 hashes to treat as known placeholder covers, in addition to the built-in ones" ;;
    *) echo "" ;;
  esac
}

bs::config_default_display() {
  case "$1" in
    curl_bin) echo "auto-detected" ;;
    http_request_delay_min) echo "$BS_HTTP_REQUEST_DELAY_MIN_DEFAULT" ;;
    http_request_delay_max) echo "$BS_HTTP_REQUEST_DELAY_MAX_DEFAULT" ;;
    http_retry_delays) echo "$BS_HTTP_RETRY_DELAYS_DEFAULT" ;;
    discovery_root_url) echo "$BS_DISCOVERY_ROOT_URL_DEFAULT" ;;
    category_cache_ttl) echo "$BS_CATEGORY_CACHE_TTL_DEFAULT" ;;
    category_settle_period) echo "$BS_CATEGORY_SETTLE_PERIOD_DEFAULT" ;;
    category_full_sync_max_interval) echo "$BS_CATEGORY_FULL_SYNC_MAX_INTERVAL_DEFAULT" ;;
    category_full_sync_ramp) echo "$BS_CATEGORY_FULL_SYNC_RAMP_DEFAULT" ;;
    image_width) echo "$BS_IMAGE_WIDTH_DEFAULT" ;;
    image_height) echo "$BS_IMAGE_HEIGHT_DEFAULT" ;;
    image_format) echo "$BS_IMAGE_FORMAT_DEFAULT" ;;
    known_placeholder_hashes) echo "(none -- built-in hashes are always checked regardless)" ;;
    *) echo "" ;;
  esac
}
