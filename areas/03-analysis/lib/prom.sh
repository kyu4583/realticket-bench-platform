#!/usr/bin/env bash
# areas/03-analysis/lib/prom.sh — Prometheus query_range 수집 (atomic write)
# Source: areas/03-analysis/README.md § 분석 모듈 스펙

# ─── collect_prometheus: queries[] 각각 수집 ───
# 인자: <prom_url> <iter_dir> <iter_start_ts> <iter_end_ts> <manifest>
collect_prometheus() {
  local prom_url="$1" iter_dir="$2" iter_start="$3" iter_end="$4" manifest="$5"
  local prom_step
  prom_step=$(parse_duration "$(manifest_yq 'prom_step' "$manifest")")
  [[ -z "$prom_step" || "$prom_step" == "null" ]] && prom_step=1

  local q_count
  q_count=$(manifest_yq 'queries | length' "$manifest")
  [[ "$q_count" == "null" || -z "$q_count" ]] && q_count=0

  local i=0
  while [[ $i -lt $q_count ]]; do
    local q_name q_promql out final
    q_name=$(manifest_yq "queries[$i].name" "$manifest")
    q_promql=$(manifest_yq "queries[$i].promql" "$manifest")
    out="$iter_dir/prom_${q_name}.json.tmp.$$"
    final="$iter_dir/prom_${q_name}.json"

    local resp_status
    resp_status=$(curl -s -o "$out" -w '%{http_code}' -G "$prom_url/api/v1/query_range" \
      --data-urlencode "query=$q_promql" \
      --data-urlencode "start=$iter_start" \
      --data-urlencode "end=$iter_end" \
      --data-urlencode "step=$prom_step") || resp_status="000"

    if [[ "$resp_status" == "200" ]] && jq -e '.status == "success"' "$out" >/dev/null 2>&1; then
      # data.result == [] (200·success·empty) 도 측정 실패로 기록
      local n_series
      n_series=$(jq '.data.result | length' "$out" 2>/dev/null || echo 0)
      if [[ "$n_series" == "0" ]]; then
        echo '-' > "$final"
        rm -f "$out"
        log WARN "collect_prometheus: query=$q_name http=200 BUT data.result is empty (recorded -)"
      else
        mv "$out" "$final"
      fi
    else
      # status != success → '-' 기록 (graceful degradation)
      echo '-' > "$final"
      rm -f "$out"
      log WARN "collect_prometheus: query=$q_name http=$resp_status (recorded -)"
    fi
    i=$((i + 1))
  done
  log INFO "collect_prometheus: $q_count queries → $iter_dir"
}
