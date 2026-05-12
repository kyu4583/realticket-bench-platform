#!/usr/bin/env bash
# areas/04-gatling-integration/lib/gatling.sh — Gatling 호출 + VM 이미지 빌드
# Source: areas/04-gatling-integration/README.md § -P 키 표 (8개) + prepare_gatling_branch() 수행 순서
# Source: areas/05-realticket-integration/README.md § build_vm_images() VM 빌드 4단계
# Source: areas/02-orchestration/README.md § 이미지 swap·stack restart 절차

# ─── run_gatling: 8 -P 키 + simulation.log 수집 ───
# 인자: <slot_idx> <plan_path> <iter_dir>
# 슬롯별 시나리오 변수는 SLOT_* 배열로 외부 주입 (없으면 default)
run_gatling() {
  local slot_idx="$1" plan_path="$2" iter_dir="$3"
  local target="${SLOT_TARGETS[$slot_idx]:-http://192.168.138.2:8080}"
  local sub_type="${SLOT_SUBSCRIPTION[$slot_idx]:-SSE}"
  local scenario="${SLOT_SCENARIO[$slot_idx]:-LOGIN_ONLY}"
  local target_event="${SLOT_TARGET_EVENT[$slot_idx]:-1}"
  local user_count="${SLOT_USER_COUNT[$slot_idx]:-200}"
  local booking_amount="${SLOT_BOOKING_AMOUNT[$slot_idx]:-4}"
  local max_retry="${SLOT_MAX_RETRY[$slot_idx]:-100}"
  local test_account_already_stored="${BENCH_TEST_ACCOUNT_ALREADY_STORED:-false}"
  local waiting_queue_user_count="${WAITING_QUEUE_USER_COUNT:-1300}"
  local waiting_queue_permission_ramp_ms="${WAITING_QUEUE_PERMISSION_RAMP_MILLIS:-10000}"
  local waiting_queue_pre_subscription_wait_ms="${WAITING_QUEUE_PRE_SUBSCRIPTION_WAIT_MILLIS:-50000}"
  local waiting_queue_subscription_ramp_ms="${WAITING_QUEUE_SUBSCRIPTION_RAMP_MILLIS:-10000}"
  local waiting_queue_hold_ms="${WAITING_QUEUE_HOLD_MILLIS:-120000}"

  # cd + ./gradlew 패턴 (04 contract 라인 160-169 — working dir 외부 repo 루트로)
  (cd "$GATLING_DIR" && \
    ./gradlew gatlingRunAndArchive \
      -PsubscriptionType="$sub_type" \
      -PscenarioMode="$scenario" \
      -PtargetUrl="${target#http://}" \
      -PtargetEvent="$target_event" \
      -PdynamicUserCount="$user_count" \
      -PfixedBookingAmount="$booking_amount" \
      -PmaxRetryInBookingConflict="$max_retry" \
      -PtestAccountAlreadyStored="$test_account_already_stored" \
      -PwaitingQueueUserCount="$waiting_queue_user_count" \
      -PwaitingQueuePermissionRampMillis="$waiting_queue_permission_ramp_ms" \
      -PwaitingQueuePreSubscriptionWaitMillis="$waiting_queue_pre_subscription_wait_ms" \
      -PwaitingQueueSubscriptionRampMillis="$waiting_queue_subscription_ramp_ms" \
      -PwaitingQueueHoldMillis="$waiting_queue_hold_ms" \
      -PplanPath="$plan_path") || return 1

  # archive 의 latest 결과를 iter_dir 로 복사 (04 contract 라인 174-181)
  # ls -td + head -1 → find + sort -rn 으로 교체.
  # SIGPIPE/locale 의존 회피 + 부분 작성 디렉토리 선택 위험 완화.
  local archive_root="$GATLING_DIR/archive/reports"
  local latest_dir=""
  if compgen -G "$archive_root/results_*" >/dev/null; then
    latest_dir=$(find "$archive_root" -maxdepth 1 -mindepth 1 -type d -name 'results_*' \
                 -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  fi
  if [[ -z "$latest_dir" || ! -d "$latest_dir" ]]; then
    log WARN "run_gatling: no archive dir found under $archive_root/"
    return 1
  fi
  # Gatling HTML report 복사 (사용자 검토용)
  # 원천은 Gatling 기본 리포트 경로(app/build/reports/gatling)의 최신 디렉토리.
  # iter_dir/gatling-report/index.html 로 바로 열 수 있게 디렉토리 내용을 복사한다.
  local report_root="$GATLING_DIR/app/build/reports/gatling"
  local latest_report_dir=""
  if compgen -G "$report_root/*" >/dev/null; then
    latest_report_dir=$(find "$report_root" -maxdepth 1 -mindepth 1 -type d \
                        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  fi
  if [[ -n "$latest_report_dir" && -d "$latest_report_dir" ]]; then
    mkdir -p "$iter_dir/gatling-report"
    cp -R "$latest_report_dir"/. "$iter_dir/gatling-report/" \
      || log WARN "run_gatling: failed to copy Gatling report from $latest_report_dir"
    printf '%s\n' "$latest_report_dir" > "$iter_dir/gatling-report-source.txt" || true
  else
    log WARN "run_gatling: no Gatling HTML report found under $report_root/"
  fi
  # simulation.log 복사 (03-analysis 입력)
  find "$latest_dir" -name 'simulation.log' -exec cp -f {} "$iter_dir/simulation.log" \; || true
  # effective-config.json 복사 (04 contract 라인 180 검증 표시)
  cp -f "$latest_dir/effective-config.json" "$iter_dir/effective-config.json" 2>/dev/null || true
  # Plan.json 도 iter_dir 에 복사 — prom_query.py 가
  # iter_dir/Plan.json 을 region 슬라이싱 입력으로 사용. 미복사 시 매번
  # 'Plan.json not found' 에러 반환.
  if [[ "${WAITING_QUEUE_NO_PLAN:-0}" == "1" ]]; then
    log INFO "run_gatling: Plan.json copy skipped for no-plan waiting queue scenario"
  else
    cp -f "$GATLING_DIR/$plan_path" "$iter_dir/Plan.json" 2>/dev/null \
      || log WARN "run_gatling: plan_path file not found at $GATLING_DIR/$plan_path"
  fi
  log INFO "run_gatling: completed slot=$slot_idx → $iter_dir"
}

# ─── build_vm_images: VM 빌드 + stack deploy + force-restart ───
# 인자: <manifest_id> <slot_names...>
# 슬롯 1개 시 메타 브랜치 1회, 슬롯 ≥ 2 시 슬롯 브랜치별 N회 빌드
build_vm_images() {
  local manifest_id="$1"
  shift
  local slot_names=("$@")

  if declare -F validate_realticket_slot_source_refs >/dev/null 2>&1; then
    git -C "$REALTICKET_DIR" fetch origin
    validate_realticket_slot_source_refs "$manifest_id" "${slot_names[@]}"
  fi

  # 'git checkout <tree-ish> -- <file>' 은 파일을 stage 에 올린다.
  # 이전 run 의 stack deploy 가 prometheus.yml 을 stage 에 남겨두면 다음 run 의
  # git checkout -B 가 거부된다. git reset --hard HEAD 로 index+worktree 를 HEAD 로 리셋한다.
  # VM repo 는 스크립트가 완전 관리하므로 --hard 는 안전하다.
  local _hard_reset="git reset --hard HEAD 2>/dev/null || true"

  if [[ ${#slot_names[@]} -le 1 ]]; then
    # 단일 슬롯 — 메타 브랜치 (05 README § VM 빌드 4단계 — origin 강제 동기화)
    ssh "$VM_HOST" "cd ~/web04-RealTicket && git fetch origin && $_hard_reset && git checkout -B 'bench/$manifest_id/meta' 'origin/bench/$manifest_id/meta' && docker build -f back/Dockerfile.dev-in-local -t 'nest:$manifest_id' back/" \
      || die "build_vm_images failed for $manifest_id"
  else
    for slot in "${slot_names[@]}"; do
      [[ -z "$slot" ]] && continue
      ssh "$VM_HOST" "cd ~/web04-RealTicket && git fetch origin && $_hard_reset && git checkout -B 'bench/$manifest_id/$slot' 'origin/bench/$manifest_id/$slot' && docker build -f back/Dockerfile.dev-in-local -t 'nest:$manifest_id-$slot' back/" \
        || die "build_vm_images failed for $manifest_id/$slot"
    done
  fi

  # bench-stack/<id>.yml 가져와서 stack deploy (메타 브랜치 origin 기준)
  # git checkout origin/bench/$manifest_id/meta 로 origin 최신 파일을 직접 취득 (로컬 브랜치 캐시 우회)
  # stack deploy 후 git reset --hard 로 stage 를 정리해 다음 run 의 checkout 충돌 방지
  remove_realticket_stack_if_present
  ssh "$VM_HOST" "cd ~/web04-RealTicket && git fetch origin && $_hard_reset && git checkout 'origin/bench/$manifest_id/meta' -- 'bench-stack/$manifest_id.yml' 'prometheus/prometheus.yml' && docker stack deploy -c 'bench-stack/$manifest_id.yml' realticket && git reset --hard HEAD" \
    || die "stack deploy failed for $manifest_id"

  # force-restart (areas/02-orchestration/README.md § 이미지 swap·stack restart 절차) — 안전판
  ssh "$VM_HOST" 'docker service update --force realticket_mysql' || true
  ssh "$VM_HOST" 'docker service update --force realticket_prometheus' || true
  ssh "$VM_HOST" 'docker service update --force realticket_nest-baseline' || true
  ssh "$VM_HOST" 'docker service update --force realticket_nest-candidate' 2>/dev/null || true
  _wait_stack_healthy
  log INFO "build_vm_images: build + stack deploy + force-restart + health check completed for $manifest_id"
}

remove_realticket_stack_if_present() {
  local stack_name="${REALTICKET_STACK_NAME:-realticket}"
  local timeout_s="${STACK_REMOVE_TIMEOUT_S:-180}"
  local interval="${STACK_REMOVE_POLL_INTERVAL_S:-5}"

  [[ "$stack_name" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "remove_realticket_stack_if_present: invalid stack name '$stack_name'"
  [[ "$timeout_s" =~ ^[0-9]+$ && "$timeout_s" -gt 0 ]] \
    || die "remove_realticket_stack_if_present: invalid timeout '$timeout_s'"
  [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] \
    || die "remove_realticket_stack_if_present: invalid interval '$interval'"

  local stacks
  stacks=$(ssh "$VM_HOST" "docker stack ls --format '{{.Name}}'") \
    || die "remove_realticket_stack_if_present: docker stack ls failed on $VM_HOST"

  if printf '%s\n' "$stacks" | grep -Fx "$stack_name" >/dev/null; then
    log INFO "remove_realticket_stack_if_present: removing existing stack '$stack_name'"
    ssh "$VM_HOST" "docker stack rm '$stack_name'" \
      || die "remove_realticket_stack_if_present: docker stack rm failed for '$stack_name'"
    _wait_stack_removed "$stack_name" "$timeout_s" "$interval"
  else
    log INFO "remove_realticket_stack_if_present: stack '$stack_name' not present"
  fi
}

_wait_stack_removed() {
  local stack_name="$1"
  local timeout_s="$2"
  local interval="$3"
  local deadline=$(( $(date +%s) + timeout_s ))

  log INFO "_wait_stack_removed: polling stack removal (stack=$stack_name timeout=${timeout_s}s interval=${interval}s)"
  while [[ $(date +%s) -le $deadline ]]; do
    local remaining
    remaining=$(ssh "$VM_HOST" \
      "svc=\$(docker service ls --filter label=com.docker.stack.namespace=$stack_name --format '{{.Name}}' | wc -l); ctr=\$(docker ps -a --filter label=com.docker.stack.namespace=$stack_name --format '{{.ID}}' | wc -l); net=\$(docker network ls --filter label=com.docker.stack.namespace=$stack_name --format '{{.Name}}' | wc -l); echo \$((svc + ctr + net))" \
      2>/dev/null) || remaining=999
    remaining="${remaining//[[:space:]]/}"
    if [[ "$remaining" == "0" ]]; then
      log INFO "_wait_stack_removed: stack '$stack_name' fully removed"
      return 0
    fi
    log INFO "_wait_stack_removed: remaining resources=$remaining — retry in ${interval}s"
    sleep "$interval"
  done
  die "_wait_stack_removed: stack '$stack_name' still has resources after ${timeout_s}s"
}

# ─── _wait_stack_healthy: realticket 스택 모든 서비스 REPLICAS N/N 확인 ───
# STACK_HEALTH_TIMEOUT_S (기본 90초) 초과 시 die
_wait_stack_healthy() {
  local timeout_s="${STACK_HEALTH_TIMEOUT_S:-90}"
  local interval=5
  local deadline=$(( $(date +%s) + timeout_s ))
  log INFO "_wait_stack_healthy: polling realticket stack (timeout=${timeout_s}s, interval=${interval}s)"
  while [[ $(date +%s) -le $deadline ]]; do
    local replicas_out svc_count unhealthy
    replicas_out=$(ssh "$VM_HOST" \
      "docker service ls --filter name=realticket --format '{{.Replicas}}'" 2>/dev/null) || replicas_out=""
    svc_count=$(printf '%s\n' "$replicas_out" | grep -c '[0-9]' 2>/dev/null || echo 0)
    unhealthy=$(printf '%s\n' "$replicas_out" \
      | awk -F'/' 'NF>=2 && $1+0 < $2+0 {c++} END {print c+0}')
    if [[ "$svc_count" -gt 0 && "$unhealthy" -eq 0 ]]; then
      log INFO "_wait_stack_healthy: all ${svc_count} realticket service(s) healthy (replicas matched)"
      return 0
    fi
    log INFO "_wait_stack_healthy: ${unhealthy}/${svc_count} not ready — retry in ${interval}s"
    sleep "$interval"
  done
  die "_wait_stack_healthy: stack not healthy after ${timeout_s}s — run 'docker service ls' on VM to investigate"
}
