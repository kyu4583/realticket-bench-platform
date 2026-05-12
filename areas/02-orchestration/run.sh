#!/usr/bin/env bash
# areas/02-orchestration/run.sh — 단일 진입점 (Lock #1).
# 사용: bash areas/02-orchestration/run.sh <manifest.yaml>
# Background: nohup bash areas/02-orchestration/run.sh <manifest.yaml> >/dev/null 2>&1 & disown
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
  declare -g cleanup_external_repos=0
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
  local run_id_prefix utc_ts run_id manifest_results_dir
  run_id_prefix=$(manifest_yq 'run_id_prefix' "$manifest")
  utc_ts=$(date -u +%Y%m%d-%H%M%S)
  [[ "$run_id_prefix" == "null" || -z "$run_id_prefix" ]] && run_id_prefix="$MANIFEST_ID"
  [[ "$run_id_prefix" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "run_id_prefix 가 [A-Za-z0-9_-]+ 패턴 위반: $run_id_prefix"

  # 실행 전 구현 품질 gate:
  # 매니페스트 작성 세션은 Gatling read-only 리서치 + 구현 계획 기록만 수행하고,
  # 구현 세션이 완료 표시를 남긴 뒤에만 실제 벤치마크를 실행한다.
  local impl_status gatling_research gatling_change_count
  impl_status=$(manifest_yq 'implementation_plan.status' "$manifest")
  [[ "$impl_status" == "completed" ]] \
    || die "implementation_plan.status must be completed before execution (got: ${impl_status:-missing})"
  gatling_research=$(manifest_yq 'implementation_plan.gatling.research_summary' "$manifest")
  [[ "$gatling_research" != "null" && -n "$gatling_research" ]] \
    || die "implementation_plan.gatling.research_summary is required before execution"
  gatling_change_count=$(manifest_yq 'implementation_plan.gatling.change_plan | length' "$manifest")
  if ! [[ "$gatling_change_count" =~ ^[0-9]+$ ]] || (( gatling_change_count < 1 )); then
    die "implementation_plan.gatling.change_plan must contain at least one planned change before execution"
  fi
  if [[ "${BENCH_PREFLIGHT_ONLY:-0}" == "1" ]]; then
    log INFO "preflight passed for manifest_id=$MANIFEST_ID"
    return 0
  fi

  run_id="${run_id_prefix}-${utc_ts}"
  manifest_results_dir="$REPO_ROOT/bench/results/$MANIFEST_ID"
  run_dir="$manifest_results_dir/$run_id"
  mkdir -p "$run_dir"
  : > "$run_dir/run.log"
  exec > >(tee -a "$run_dir/run.log") 2>&1

  # RUNNING 마커 (Lock #4)
  : > "$run_dir/RUNNING"
  log INFO "main: run_id=$run_id manifest_id=$MANIFEST_ID run_dir=$run_dir"

  # SLOT_TARGETS 배열 빌드 (manifest.slots[].targetUrl)
  local slot_count slot_names
  slot_count=$(manifest_yq 'slots | length' "$manifest")
  [[ "$slot_count" == "null" || -z "$slot_count" ]] && slot_count=1
  # slots: [] 명시적 빈 배열 → modulo 0 차단
  [[ "$slot_count" -ge 1 ]] || die "slots[] 배열에 슬롯이 1개 이상 필요"
  declare -ga SLOT_TARGETS=()
  declare -ga SLOT_NAMES=()
  declare -ga SLOT_SCENARIO=()
  declare -ga SLOT_SOURCE_BRANCH=()
  local i=0
  while [[ $i -lt $slot_count ]]; do
    local turl sname smode sbranch
    turl=$(manifest_yq "slots[$i].targetUrl" "$manifest")
    sname=$(manifest_yq "slots[$i].name" "$manifest")
    smode=$(manifest_yq "slots[$i].scenario_mode" "$manifest")
    sbranch=$(manifest_yq "slots[$i].source_branch" "$manifest")
    [[ "$turl"    == "null" || -z "$turl"    ]] && turl="http://192.168.138.2:8080"
    [[ "$sname"   == "null" || -z "$sname"   ]] && sname="slot-$i"
    [[ "$smode"   == "null" || -z "$smode"   ]] && smode="LOGIN_ONLY"
    [[ "$sbranch" == "null" || -z "$sbranch" ]] && sbranch=""
    SLOT_TARGETS+=("$turl")
    SLOT_NAMES+=("$sname")
    SLOT_SCENARIO+=("$smode")
    SLOT_SOURCE_BRANCH+=("$sbranch")
    i=$((i + 1))
  done
  export SLOT_TARGETS SLOT_NAMES SLOT_SCENARIO SLOT_SOURCE_BRANCH
  slot_names=$(manifest_yq 'slots[].name' "$manifest")
  # slot 이름도 git branch / docker image tag / ssh 인자로 들어가므로 검증
  for slot in $slot_names; do
    [[ "$slot" =~ ^[A-Za-z0-9_-]+$ ]] || die "slot name 패턴 위반: $slot"
  done

  # 매니페스트 ID 브랜치 lifecycle
  local scenario_family plan_config_used
  scenario_family=$(manifest_yq 'context.load_model.scenario_family' "$manifest")
  plan_config_used=$(manifest_yq 'context.plan_config.used' "$manifest")
  if [[ "$scenario_family" == "waiting_queue_sse" || "$plan_config_used" == "false" ]]; then
    local alpha_test_account wq_clients wq_permission_ramp wq_pre_subscription_wait wq_subscription_ramp wq_hold
    alpha_test_account=$(manifest_yq 'bench_stack.alpha_test_account' "$manifest")
    wq_clients=$(manifest_yq 'context.load_model.concurrent_clients' "$manifest")
    wq_permission_ramp=$(manifest_yq 'context.load_model.permission_ramp_up' "$manifest")
    wq_pre_subscription_wait=$(manifest_yq 'context.load_model.pre_subscription_wait' "$manifest")
    wq_subscription_ramp=$(manifest_yq 'context.load_model.subscription_ramp_up' "$manifest")
    wq_hold=$(manifest_yq 'context.load_model.hold' "$manifest")
    [[ "$alpha_test_account" == "null" || -z "$alpha_test_account" ]] && alpha_test_account=false
    [[ "$wq_clients" == "null" || -z "$wq_clients" ]] && wq_clients=1300
    [[ "$wq_permission_ramp" == "null" || -z "$wq_permission_ramp" ]] && wq_permission_ramp="10s"
    [[ "$wq_pre_subscription_wait" == "null" || -z "$wq_pre_subscription_wait" ]] && wq_pre_subscription_wait="50s"
    [[ "$wq_subscription_ramp" == "null" || -z "$wq_subscription_ramp" ]] && wq_subscription_ramp="10s"
    [[ "$wq_hold" == "null" || -z "$wq_hold" ]] && wq_hold="2m"
    [[ "$wq_clients" =~ ^[0-9]+$ && "$wq_clients" -gt 0 ]] \
      || die "context.load_model.concurrent_clients must be a positive integer"

    export WAITING_QUEUE_NO_PLAN=1
    export BENCH_TEST_ACCOUNT_ALREADY_STORED="$alpha_test_account"
    export WAITING_QUEUE_USER_COUNT="$wq_clients"
    export WAITING_QUEUE_PERMISSION_RAMP_MILLIS=$(( $(parse_duration "$wq_permission_ramp") * 1000 ))
    export WAITING_QUEUE_PRE_SUBSCRIPTION_WAIT_MILLIS=$(( $(parse_duration "$wq_pre_subscription_wait") * 1000 ))
    export WAITING_QUEUE_SUBSCRIPTION_RAMP_MILLIS=$(( $(parse_duration "$wq_subscription_ramp") * 1000 ))
    export WAITING_QUEUE_HOLD_MILLIS=$(( $(parse_duration "$wq_hold") * 1000 ))
    log INFO "main: waiting queue no-plan mode -- clients=$WAITING_QUEUE_USER_COUNT permission_ramp_ms=$WAITING_QUEUE_PERMISSION_RAMP_MILLIS pre_sub_wait_ms=$WAITING_QUEUE_PRE_SUBSCRIPTION_WAIT_MILLIS subscription_ramp_ms=$WAITING_QUEUE_SUBSCRIPTION_RAMP_MILLIS hold_ms=$WAITING_QUEUE_HOLD_MILLIS test_account_already_stored=$BENCH_TEST_ACCOUNT_ALREADY_STORED"
  else
    export WAITING_QUEUE_NO_PLAN=0
  fi

  local gatling_base_ref gatling_local_only
  gatling_base_ref=$(manifest_yq 'implementation_plan.gatling.base' "$manifest")
  gatling_local_only=$(manifest_yq 'implementation_plan.gatling.local_only' "$manifest")
  [[ "$gatling_base_ref" == "null" || -z "$gatling_base_ref" ]] && gatling_base_ref="origin/main"
  [[ "$gatling_local_only" == "true" ]] && export GATLING_LOCAL_ONLY=1 || export GATLING_LOCAL_ONLY=0
  export GATLING_BASE_REF="$gatling_base_ref"

  cleanup_external_repos=1
  prepare_gatling_branch "$MANIFEST_ID"
  # shellcheck disable=SC2086
  prepare_realticket_branches "$MANIFEST_ID" $slot_names
  # shellcheck disable=SC2086
  ensure_realticket_prometheus_scrape_interval "$MANIFEST_ID" $slot_names
  generate_bench_stack_yml "$MANIFEST_ID" "$manifest"
  # 메타 yml commit + 슬롯 cherry-pick 직후 origin push (VM build_vm_images 의 git fetch 가 본 push 의 직접 소비자)
  # shellcheck disable=SC2086
  push_realticket_branches_to_origin "$MANIFEST_ID" $slot_names
  apply_untracked_overrides "$MANIFEST_ID" "$run_dir"
  # shellcheck disable=SC2086
  build_vm_images "$MANIFEST_ID" $slot_names

  # 매니페스트 변수 추출
  local prom_url plan_path warmup_s cooldown_s total_iter
  prom_url=$(manifest_yq 'prom_url' "$manifest")
  plan_path=$(manifest_yq 'plan_path' "$manifest")
  warmup_s=$(parse_duration "$(manifest_yq 'warmup' "$manifest")")
  cooldown_s=$(parse_duration "$(manifest_yq 'cooldown' "$manifest")")

  # per_run 도출: Plan.json 의 stats.simulation_duration_ms × 1.1 (ceil)
  # PlanGenerator 가 자연 종료로 simulation_duration_ms 를 결정 — 매니페스트는 per_run 입력 X
  local plan_full_path config_file plan_max_ms per_run_ms main_booking_ms main_booking_s
  local static_wait_ms runner_overhead_s estimated_iter_s min_iter_estimate_s
  if [[ "${WAITING_QUEUE_NO_PLAN:-0}" == "1" ]]; then
    runner_overhead_s="${BENCH_RUNNER_OVERHEAD_S:-20}"
    [[ "$runner_overhead_s" =~ ^[0-9]+$ ]] || die "BENCH_RUNNER_OVERHEAD_S must be a non-negative integer"
    plan_max_ms=$(( WAITING_QUEUE_PERMISSION_RAMP_MILLIS + WAITING_QUEUE_PRE_SUBSCRIPTION_WAIT_MILLIS + WAITING_QUEUE_SUBSCRIPTION_RAMP_MILLIS + WAITING_QUEUE_HOLD_MILLIS ))
    [[ "$plan_max_ms" -gt 0 ]] || die "waiting queue timing total must be > 0"
    per_run_ms="$plan_max_ms"
    main_booking_ms="$per_run_ms"
    main_booking_s=$(ceil_div "$main_booking_ms" 1000)
    static_wait_ms=0
    estimated_iter_s=$(derive_initial_iter_wall_s "$main_booking_ms" "$static_wait_ms" "$runner_overhead_s")
    min_iter_estimate_s=$(derive_initial_iter_wall_s "$main_booking_ms" "$static_wait_ms" 0)
    log INFO "main: waiting queue timing estimate -- permission_ramp_ms=$WAITING_QUEUE_PERMISSION_RAMP_MILLIS pre_sub_wait_ms=$WAITING_QUEUE_PRE_SUBSCRIPTION_WAIT_MILLIS subscription_ramp_ms=$WAITING_QUEUE_SUBSCRIPTION_RAMP_MILLIS hold_ms=$WAITING_QUEUE_HOLD_MILLIS runner_overhead_s=$runner_overhead_s estimated_iter_s=$estimated_iter_s"
    log INFO "main: analysis region derived -- plan_max_ms=$plan_max_ms main_booking_ms=$main_booking_ms (main_booking_s=$main_booking_s)"
  else
    plan_full_path="$GATLING_DIR/$plan_path"
  [[ -f "$plan_full_path" ]] || die "Plan.json not found: $plan_full_path (PlanGenerator 실행 누락 의심)"
  plan_max_ms=$(jq -r '.stats.simulation_duration_ms // 0' "$plan_full_path")
  [[ "$plan_max_ms" -gt 0 ]] || die "Plan.json stats.simulation_duration_ms 가 0 — Plan 미생성 의심"
  # ceil(plan_max_ms × 1.1) ms → ceil(_ms / 1000) s
  per_run_ms=$(( (plan_max_ms * 11 + 9) / 10 ))
  main_booking_ms="$per_run_ms"
  main_booking_s=$(ceil_div "$main_booking_ms" 1000)
  config_file="$GATLING_DIR/app/src/gatling/java/simulations/config/Config.java"
  static_wait_ms=$(derive_gatling_static_wait_ms "$config_file")
  runner_overhead_s="${BENCH_RUNNER_OVERHEAD_S:-20}"
  [[ "$runner_overhead_s" =~ ^[0-9]+$ ]] || die "BENCH_RUNNER_OVERHEAD_S must be a non-negative integer"
  estimated_iter_s=$(derive_initial_iter_wall_s "$main_booking_ms" "$static_wait_ms" "$runner_overhead_s")
  min_iter_estimate_s=$(derive_initial_iter_wall_s "$main_booking_ms" "$static_wait_ms" 0)
  log INFO "main: timing estimate -- plan_max_ms=$plan_max_ms main_booking_ms=$main_booking_ms static_wait_ms=$static_wait_ms runner_overhead_s=$runner_overhead_s estimated_iter_s=$estimated_iter_s"
  log INFO "main: analysis region derived -- plan_max_ms=$plan_max_ms main_booking_ms=$main_booking_ms (main_booking_s=$main_booking_s)"
  fi

  local manifest_iterations manifest_duration duration_mode dur_s duration_budget_s duration_deadline_epoch
  manifest_iterations=$(manifest_yq 'iterations' "$manifest")
  manifest_duration=$(manifest_yq 'duration' "$manifest")
  duration_mode=0
  dur_s=0
  duration_budget_s=0
  duration_deadline_epoch=0

  if [[ "$manifest_iterations" != "null" && -n "$manifest_iterations" && "$manifest_duration" != "null" && -n "$manifest_duration" ]]; then
    die "iterations and duration are mutually exclusive"
  fi
  if [[ "$manifest_iterations" == "null" || -z "$manifest_iterations" ]] && [[ "$manifest_duration" == "null" || -z "$manifest_duration" ]]; then
    die "iterations or duration required"
  fi
  if [[ "$manifest_iterations" == "null" || -z "$manifest_iterations" ]]; then
    duration_mode=1
    dur_s=$(parse_duration "$manifest_duration")
    duration_budget_s=$(( dur_s - warmup_s ))
    [[ "$duration_budget_s" -gt 0 ]] || die "duration must be greater than warmup"
    local denom=$(( estimated_iter_s + cooldown_s ))
    [[ "$denom" -gt 0 ]] || die "estimated iter + cooldown must be > 0s in duration mode"
    total_iter=$(( duration_budget_s / denom ))
    [[ "$total_iter" -gt 0 ]] || die "computed total_iter=$total_iter is 0 (check duration/estimated iter/cooldown)"
    log INFO "main: duration mode -- duration_s=$dur_s warmup_s=$warmup_s cooldown_s=$cooldown_s initial_total_iter_estimate=$total_iter"
  else
    [[ "$manifest_iterations" =~ ^[0-9]+$ && "$manifest_iterations" -gt 0 ]] || die "iterations must be a positive integer"
    total_iter="$manifest_iterations"
    log INFO "main: iterations mode -- total_iter=$total_iter estimated_iter_s=$estimated_iter_s cooldown_s=$cooldown_s"
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
  if (( duration_mode == 1 )); then
    duration_deadline_epoch=$(( run_start_ts + duration_budget_s ))
  fi
  failed_iters=0
  last_failed_iter=-1
  local executed_iters measured_iter_count measured_iter_total_s
  executed_iters=0
  measured_iter_count=0
  measured_iter_total_s=0

  # iter 루프 (current_iter / current_slot 은 cleanup 이 참조 — global 유지)
  current_iter=1
  while :; do
    if (( duration_mode == 1 )); then
      local now_s remaining_s needed_next_s
      now_s=$(date +%s)
      remaining_s=$(( duration_deadline_epoch - now_s ))
      needed_next_s=$(( estimated_iter_s + cooldown_s ))
      if (( remaining_s < needed_next_s )); then
        log INFO "main: duration deadline reached -- executed_iters=$executed_iters remaining_s=$remaining_s needed_next_s=$needed_next_s estimated_iter_s=$estimated_iter_s cooldown_s=$cooldown_s"
        break
      fi
      total_iter=$(( executed_iters + remaining_s / needed_next_s ))
      (( total_iter < current_iter )) && total_iter="$current_iter"
    else
      (( current_iter <= total_iter )) || break
    fi
    local slot_idx
    slot_idx=$(get_slot_for_iter "$current_iter" "$slot_count")
    current_slot="${SLOT_NAMES[$slot_idx]:-slot-$slot_idx}"
    local iter_dir="$run_dir/iter-${current_iter}-${current_slot}"
    mkdir -p "$iter_dir"

    local iter_start iter_estimate_s
    iter_estimate_s="$estimated_iter_s"
    iter_start=$(date +%s)
    write_progress "$run_dir" "$current_iter" "$total_iter" "run" "$current_slot" "$failed_iters" "$run_start_ts" "$iter_estimate_s" "$cooldown_s"

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
      executed_iters=$current_iter
      log WARN "main: iter=$current_iter reset failed (event=${RESET_FAILED_EVENT:-?} http=${RESET_FAILED_HTTP:-?}) — skip run_gatling/prom, continuing"
      write_progress "$run_dir" "$current_iter" "$total_iter" "cooldown" "$current_slot" "$failed_iters" "$run_start_ts" "$estimated_iter_s" "$cooldown_s"
      sleep "$cooldown_s"
      current_iter=$((current_iter + 1))
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
    local iter_wall_end measured_iter_s
    iter_wall_end=$(date +%s)
    measured_iter_s=$(( iter_wall_end - iter_start ))
    write_iter_meta "$iter_dir" "$current_iter" "$current_slot" "$plan_path" "$iter_start" "$iter_end" "$per_run_ms" \
      "$main_booking_ms" "$iter_estimate_s" "$static_wait_ms" "$runner_overhead_s" "$measured_iter_s"
    # prom_query.py: prom_*.json + iter_meta.json → prom_metrics.json (summarize.py가 읽는 파일)
    if [[ -f "$REPO_ROOT/areas/03-analysis/analyze/prom_query.py" ]]; then
      python3 "$REPO_ROOT/areas/03-analysis/analyze/prom_query.py" \
        --iter "$iter_dir" --manifest "$manifest" \
        || log WARN "prom_query.py failed for $iter_dir"
    else
      log WARN "prom_query.py not found — skipping"
    fi

    executed_iters=$current_iter
    measured_iter_count=$((measured_iter_count + 1))
    measured_iter_total_s=$((measured_iter_total_s + measured_iter_s))
    estimated_iter_s=$(( (measured_iter_total_s + measured_iter_count - 1) / measured_iter_count ))
    if (( estimated_iter_s < min_iter_estimate_s )); then
      estimated_iter_s="$min_iter_estimate_s"
    fi
    log INFO "main: iter timing update -- iter=$current_iter measured_iter_s=$measured_iter_s rolling_estimated_iter_s=$estimated_iter_s"

    write_progress "$run_dir" "$current_iter" "$total_iter" "cooldown" "$current_slot" "$failed_iters" "$run_start_ts" "$estimated_iter_s" "$cooldown_s"
    sleep "$cooldown_s"
    current_iter=$((current_iter + 1))
  done

  # summarize.py 호출 (non-blocking)
  if [[ -f "$REPO_ROOT/areas/03-analysis/analyze/summarize.py" ]]; then
    python3 "$REPO_ROOT/areas/03-analysis/analyze/summarize.py" "$run_dir" || log WARN "summarize.py failed"
  else
    log WARN "summarize.py not found — skipping"
  fi

  # COMPLETED 마커 (Lock #4)
  rm -f "$run_dir/RUNNING"
  cat > "$run_dir/COMPLETED" <<EOF
completed_at=$(date -u +%FT%TZ)
total_iter_executed=$executed_iters
failed_iters=$failed_iters
tools_used=curl,ssh,git,gradle,python,yq,jq
EOF
  log INFO "main: COMPLETED run_id=$run_id failed=$failed_iters"
}

main "$@"
