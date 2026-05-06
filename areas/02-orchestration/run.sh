#!/usr/bin/env bash
# areas/02-orchestration/run.sh — 단일 진입점 (Lock #1).
# 사용: bash areas/02-orchestration/run.sh <manifest.yaml>
# Background: nohup bash areas/02-orchestration/run.sh <manifest.yaml> > bench/results/<run_id>/run.log 2>&1 & disown
# Source: areas/02-orchestration/README.md § run.sh 17 함수 + § 이미지 swap·stack restart 절차

set -Eeuo pipefail  # -E (errtrace): 함수 내부 ERR 이 trap 에 전달

# ─── 경로 ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # areas/02-orchestration/
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"                  # repo root
GATLING_DIR="${GATLING_DIR:-$REPO_ROOT/../gatling-practice/realticket-gatling-simulations}"
REALTICKET_DIR="${REALTICKET_DIR:-$REPO_ROOT/../naver-boostcamp-membership/GroupProject/web04-RealTicket}"
VM_HOST="${VM_HOST:-VM_ubuntu}"
export SCRIPT_DIR REPO_ROOT GATLING_DIR REALTICKET_DIR VM_HOST

# ─── source lib (순서: util → lifecycle → branch → bench_stack → gatling → prom) ───
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/lifecycle.sh"
source "$SCRIPT_DIR/lib/branch.sh"
source "$SCRIPT_DIR/lib/bench_stack.sh"
source "$REPO_ROOT/areas/04-gatling-integration/lib/gatling.sh"
source "$REPO_ROOT/areas/03-analysis/lib/prom.sh"

# ─── trap (정상·실패·SIGINT 모두 cleanup) ───
trap cleanup_on_exit EXIT

# ─── main 함수 ───
main() {
  local manifest="${1:-}"
  [[ -n "$manifest" && -f "$manifest" ]] || die "Usage: bash areas/02-orchestration/run.sh <manifest.yaml>"
  # cleanup_on_exit 가 참조하는 변수 — 명시적 declare -g (set -u 안전)
  declare -g run_dir="" current_iter="" current_slot=""
  check_deps

  # .env source (있으면)
  if [[ -f "$REPO_ROOT/areas/06-vm-environment/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/areas/06-vm-environment/.env"
    set +a
  fi

  # 매니페스트 파싱
  MANIFEST_ID=$(manifest_yq 'manifest_id' "$manifest")
  # 쉘 인젝션 차단 — git/ssh/sed 인자에 그대로 삽입되므로 패턴 강제
  [[ "$MANIFEST_ID" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "manifest_id 가 [A-Za-z0-9_-]+ 패턴 위반: $MANIFEST_ID"
  export MANIFEST_ID
  local run_id_prefix utc_ts run_id
  run_id_prefix=$(manifest_yq 'run_id_prefix' "$manifest")
  utc_ts=$(date -u +%Y%m%d-%H%M%S)
  [[ "$run_id_prefix" == "null" || -z "$run_id_prefix" ]] && run_id_prefix="$MANIFEST_ID"
  run_id="${run_id_prefix}-${utc_ts}"
  run_dir="$REPO_ROOT/bench/results/$run_id"
  mkdir -p "$run_dir"

  # RUNNING 마커 (Lock #5)
  : > "$run_dir/RUNNING"
  log INFO "main: run_id=$run_id manifest_id=$MANIFEST_ID"

  # SLOT_TARGETS 배열 빌드 (manifest.slots[].targetUrl)
  local slot_count slot_names
  slot_count=$(manifest_yq 'slots | length' "$manifest")
  [[ "$slot_count" == "null" || -z "$slot_count" ]] && slot_count=1
  # slots: [] 명시적 빈 배열 → modulo 0 차단
  [[ "$slot_count" -ge 1 ]] || die "slots[] 배열에 슬롯이 1개 이상 필요"
  declare -ga SLOT_TARGETS=()
  declare -ga SLOT_NAMES=()
  local i=0
  while [[ $i -lt $slot_count ]]; do
    local turl sname
    turl=$(manifest_yq "slots[$i].targetUrl" "$manifest")
    sname=$(manifest_yq "slots[$i].name" "$manifest")
    [[ "$turl"  == "null" || -z "$turl"  ]] && turl="http://192.168.138.2:8080"
    [[ "$sname" == "null" || -z "$sname" ]] && sname="slot-$i"
    SLOT_TARGETS+=("$turl")
    SLOT_NAMES+=("$sname")
    i=$((i + 1))
  done
  export SLOT_TARGETS SLOT_NAMES
  slot_names=$(manifest_yq 'slots[].name' "$manifest")
  # slot 이름도 git branch / docker image tag / ssh 인자로 들어가므로 검증
  for slot in $slot_names; do
    [[ "$slot" =~ ^[A-Za-z0-9_-]+$ ]] || die "slot name 패턴 위반: $slot"
  done

  # 매니페스트 ID 브랜치 lifecycle
  prepare_gatling_branch "$MANIFEST_ID"
  # shellcheck disable=SC2086
  prepare_realticket_branches "$MANIFEST_ID" $slot_names
  generate_bench_stack_yml "$MANIFEST_ID" "$manifest"
  # 메타 yml commit + 슬롯 cherry-pick 직후 origin push (VM build_vm_images 의 git fetch 가 본 push 의 직접 소비자)
  # shellcheck disable=SC2086
  push_realticket_branches_to_origin "$MANIFEST_ID" $slot_names
  apply_untracked_overrides "$MANIFEST_ID" "$run_dir"
  # shellcheck disable=SC2086
  build_vm_images "$MANIFEST_ID" $slot_names

  # 매니페스트 변수 추출
  local prom_url plan_path warmup_s per_run_s cooldown_s total_iter
  prom_url=$(manifest_yq 'prom_url' "$manifest")
  plan_path=$(manifest_yq 'plan_path' "$manifest")
  warmup_s=$(parse_duration "$(manifest_yq 'warmup' "$manifest")")
  per_run_s=$(parse_duration "$(manifest_yq 'per_run' "$manifest")")
  cooldown_s=$(parse_duration "$(manifest_yq 'cooldown' "$manifest")")
  total_iter=$(manifest_yq 'iterations' "$manifest")
  if [[ "$total_iter" == "null" || -z "$total_iter" ]]; then
    local dur_s
    dur_s=$(parse_duration "$(manifest_yq 'duration' "$manifest")")
    # per_run + cooldown 분모 0 방지 + total_iter > 0 검증
    local denom=$(( per_run_s + cooldown_s ))
    [[ "$denom" -gt 0 ]] || die "per_run + cooldown must be > 0s in duration mode"
    total_iter=$(( (dur_s - warmup_s) / denom ))
    [[ "$total_iter" -gt 0 ]] || die "computed total_iter=$total_iter is 0 (check duration/per_run/cooldown)"
  fi

  # ADMIN SID
  local sid
  sid=$(admin_login "${SLOT_TARGETS[0]}" "${ADMIN_ID:-}" "${ADMIN_PASSWORD:-}")
  [[ -n "$sid" ]] || die "admin_login failed"

  # warmup
  log INFO "main: warmup ${warmup_s}s"
  sleep "$warmup_s"
  local run_start_ts failed_iters last_failed_iter
  local -A slot_failed_before
  run_start_ts=$(date +%s)
  failed_iters=0
  last_failed_iter=-1

  # iter 루프 (current_iter / current_slot 은 cleanup 이 참조 — global 유지)
  for current_iter in $(seq 1 "$total_iter"); do
    local slot_idx
    slot_idx=$(get_slot_for_iter "$current_iter" "$slot_count")
    current_slot="${SLOT_NAMES[$slot_idx]:-slot-$slot_idx}"
    local iter_dir="$run_dir/iter-${current_iter}-${current_slot}"
    mkdir -p "$iter_dir"

    local iter_start
    iter_start=$(date +%s)
    write_progress "$run_dir" "$current_iter" "$total_iter" "run" "$current_slot" "$failed_iters" "$run_start_ts" "$per_run_s" "$cooldown_s"

    # event_ids (스페이스 분리 list)
    local event_ids
    event_ids=$(manifest_yq 'event_ids[]' "$manifest")
    # event_ids[] 부재 시 빈 출력 → reset silent skip 방지
    [[ -n "$event_ids" ]] || die "manifest event_ids[] is required and non-empty"

    # reset → run_gatling → collect_prom → write_iter_meta
    # reset 재시도 모두 실패 → iter 통째 즉시 실패 (사용자 결정 2026-05-04).
    # run_gatling/prom/write_iter_meta(정상) 모두 skip, iter_meta_failed 만 기록 후 다음 iter 로.
    # shellcheck disable=SC2086
    if ! reset_slots "$slot_idx" "$sid" $event_ids; then
      failed_iters=$((failed_iters + 1))
      write_iter_meta_failed "$iter_dir" "$current_iter" "$current_slot" "$plan_path" "$iter_start" \
        "${RESET_FAILED_EVENT:-?}" "${RESET_FAILED_HTTP:-?}"
      # 통합 실패 정책 (사용자 결정 2026-05-04):
      #   (A) 직전 iter 폐기 + 현재 iter 폐기 → 연속 폐기
      #   (B) 동일 슬롯에서 폐기 재발 → 그 슬롯의 BE 영구 장애 신호
      # 어느 한 조건이라도 true 면 die — cleanup_on_exit 가 FAILED 마커 + 외부 repo 복귀 처리.
      if (( current_iter == last_failed_iter + 1 )) && (( last_failed_iter > 0 )); then
        die "main: 연속 iter 폐기 — iter=$last_failed_iter, $current_iter 모두 reset 실패 (run 중단)"
      fi
      if [[ "${slot_failed_before[$slot_idx]:-0}" == "1" ]]; then
        die "main: 동일 슬롯 reset 폐기 재발 — slot=$slot_idx 두 번째 폐기 (iter=$current_iter, run 중단)"
      fi
      last_failed_iter=$current_iter
      slot_failed_before[$slot_idx]=1
      log WARN "main: iter=$current_iter reset failed (event=${RESET_FAILED_EVENT:-?} http=${RESET_FAILED_HTTP:-?}) — skip run_gatling/prom, continuing"
      write_progress "$run_dir" "$current_iter" "$total_iter" "cooldown" "$current_slot" "$failed_iters" "$run_start_ts" "$per_run_s" "$cooldown_s"
      sleep "$cooldown_s"
      continue
    fi
    run_gatling "$slot_idx" "$plan_path" "$iter_dir" || failed_iters=$((failed_iters + 1))
    local iter_end
    iter_end=$(date +%s)
    collect_prometheus "$prom_url" "$iter_dir" "$iter_start" "$iter_end" "$manifest"
    # parse_simulation_log.py: simulation.log → raw_requests.jsonl + stats.json
    if [[ -f "$REPO_ROOT/areas/03-analysis/analyze/parse_simulation_log.py" ]]; then
      python3 "$REPO_ROOT/areas/03-analysis/analyze/parse_simulation_log.py" "$iter_dir" \
        || log WARN "parse_simulation_log.py failed for $iter_dir"
    else
      log WARN "parse_simulation_log.py not found — skipping"
    fi
    write_iter_meta "$iter_dir" "$current_iter" "$current_slot" "$plan_path" "$iter_start"

    write_progress "$run_dir" "$current_iter" "$total_iter" "cooldown" "$current_slot" "$failed_iters" "$run_start_ts" "$per_run_s" "$cooldown_s"
    sleep "$cooldown_s"
  done

  # summarize.py 호출 (non-blocking)
  if [[ -f "$REPO_ROOT/areas/03-analysis/analyze/summarize.py" ]]; then
    python3 "$REPO_ROOT/areas/03-analysis/analyze/summarize.py" "$run_dir" || log WARN "summarize.py failed"
  else
    log WARN "summarize.py not found — skipping"
  fi

  # COMPLETED 마커 (Lock #5)
  rm -f "$run_dir/RUNNING"
  cat > "$run_dir/COMPLETED" <<EOF
completed_at=$(date -u +%FT%TZ)
total_iter_executed=$total_iter
failed_iters=$failed_iters
tools_used=curl,ssh,git,gradle,python,yq,jq
EOF
  log INFO "main: COMPLETED run_id=$run_id failed=$failed_iters"
}

main "$@"
