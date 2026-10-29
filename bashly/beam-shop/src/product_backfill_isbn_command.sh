: # keeps the shellcheck directive below scoped to one line, not file-wide
# shellcheck disable=SC2154 # args is bashly's global associative array
product_ids="${args[product_id]:-}"
force="${args[--force]:-}"
quiet=""
if bs::fetch_quiet "${args[--batch]:-}"; then
  quiet=1
fi

if [[ -n "${args[--report]:-}" ]]; then
  bs::isbn_anomaly_report
  exit
fi

products_dir="$(bs::products_dir)"
if [[ -n "$product_ids" ]]; then
  # shellcheck disable=SC2206 # intentional word-splitting
  product_id_array=($product_ids)
elif [[ -n "$force" ]]; then
  mapfile -t product_id_array < <(find "$products_dir" -maxdepth 1 -name '*.json' -printf '%f\n' | sed 's/\.json$//' | sort)
else
  # grep -L: records with no isbn field at all (null counts as checked)
  mapfile -t product_id_array < <(find "$products_dir" -maxdepth 1 -name '*.json' -print0 \
    | xargs -0 -r grep -L '"isbn":' | xargs -r -n1 basename | sed 's/\.json$//' | sort)
fi

total="${#product_id_array[@]}"
if (( total == 0 )); then
  echo "Every product already has an isbn field -- nothing to do (--force re-checks them all)."
  exit 0
fi

bs::init_curl_cmd || exit 1

stored=0
none=0
fail=0
n=0
for pid in "${product_id_array[@]}"; do
  n=$((n + 1))
  bs::status_line "isbn [$n/$total] $pid (stored $stored, none $none, failed $fail)" "$quiet"
  if outcome="$(bs::backfill_isbn "$pid")"; then
    if [[ "$outcome" == "none" ]]; then
      none=$((none + 1))
    else
      stored=$((stored + 1))
    fi
    [[ -n "$quiet" ]] && echo "$pid -> $outcome"
  else
    bs::status_line_clear "$quiet"
    fail=$((fail + 1))
  fi
done
bs::status_line_clear "$quiet"

echo "Checked $n product(s): $stored isbn(s) stored, $none without one, $fail failed."
anomalies="$(find "$(bs::isbn_anomalies_dir)" -maxdepth 1 -name '*.json' | wc -l)"
(( anomalies > 0 )) && echo "$anomalies product(s) with ISBN anomalies on record -- see 'beam-shop product backfill-isbn --report'."
(( fail == 0 ))
