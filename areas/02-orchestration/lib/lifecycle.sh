#!/usr/bin/env bash
# areas/02-orchestration/lib/lifecycle.sh — run 단위 라이프사이클 (admin SID·reset·alternating·progress·iter_meta·cleanup trap)
# Source: areas/02-orchestration/README.md § run.sh 17 함수
# Source: areas/05-realticket-integration/README.md § BE Endpoint 시그니처 + Admin 인증 흐름

# ─── admin_login: SID 쿠키 발급 후 echo (Lock #1 Bash 자동화) ───
# 인자: <url> <id> <pwd>
# 출력: stdout 에 SID 1줄 (실패 시 빈 문자열)
admin_login() {
  local url="$1" id="$2" pwd="$3"
  local cookies="${TMPDIR:-/tmp}/bench_cookies_$$.txt"
  # trap 으로 쿠키 파일 항상 정리 (curl 에러 포함)
  trap 'rm -f "$cookies"' RETURN
  # jq 로 JSON 안전 구성 — 특수문자 인젝션 차단
  local body
  body=$(jq -n --arg id "$id" --arg pwd "$pwd" '{loginId:$id,loginPassword:$pwd}')
  curl -s -c "$cookies" -X POST "$url/user/login" \
    -H 'Content-Type: application/json' \
    -d "$body" >/dev/null || true
  if [[ -f "$cookies" ]]; then
    # Netscape cookie file 형식: <domain>\t<flag>\t<path>\t<secure>\t<expiration>\t<name>\t<value>
    awk '$6 == "SID" { print $7 }' "$cookies" | head -1
  fi
}

# ─── reset_slots: 활성 슬롯의 event_ids 각각 POST /booking/init/:eventId ───
# Source: 05 contract § Admin 인증 흐름 라인 46-56 (이벤트 순차 + 슬롯 병렬)
# 인자: <slot_idx> <sid> <event_ids...>
#
# 실패 정책 (사용자 결정 2026-05-04):
#   - 각 event init 호출이 200 아니면 RESET_RETRY_INTERVAL_S 후 재시도, 최대 RESET_RETRY_COUNT 회.
#   - 횟수 안에 200 못 받으면 → 그 iter 통째 즉시 실패 (return 1).
#     RESET_FAILED_EVENT / RESET_FAILED_HTTP 를 export 하여 caller(run.sh main)가 iter_meta 에 기록.
#   - 부분 reset 오염 방지. 옛 best-effort all 방식은 폐기.
RESET_RETRY_COUNT="${RESET_RETRY_COUNT:-3}"
RESET_RETRY_INTERVAL_S="${RESET_RETRY_INTERVAL_S:-2}"

reset_slots() {
  local slot_idx="$1" sid="$2"
  shift 2
  local event_ids=("$@")
  local target="${SLOT_TARGETS[$slot_idx]:-http://192.168.138.2:8080}"

  for ev in "${event_ids[@]}"; do
    [[ -z "$ev" ]] && continue
    local attempt=1 code=""
    while (( attempt <= RESET_RETRY_COUNT )); do
      code=$(curl -s -X POST "${target}/booking/init/${ev}" \
        -H "Cookie: SID=$sid" \
        -o /dev/null -w '%{http_code}') || code="000"
      if [[ "$code" == "200" || "$code" == "201" ]]; then
        log INFO "reset_slots: slot=$slot_idx event=$ev http=$code attempt=$attempt"
        break
      fi
      log WARN "reset_slots: slot=$slot_idx event=$ev http=$code attempt=$attempt/$RESET_RETRY_COUNT"
      if (( attempt < RESET_RETRY_COUNT )); then
        sleep "$RESET_RETRY_INTERVAL_S"
      fi
      attempt=$((attempt + 1))
    done
    if [[ "$code" != "200" && "$code" != "201" ]]; then
      export RESET_FAILED_EVENT="$ev"
      export RESET_FAILED_HTTP="$code"
      log ERROR "reset_slots: event $ev failed after $RESET_RETRY_COUNT attempts (last http=$code) — aborting iter"
      return 1
    fi
  done
  unset RESET_FAILED_EVENT RESET_FAILED_HTTP
  return 0
}

# ─── get_slot_for_iter: alternating (Lock #3) ───
# 인자: <iter> <slots_count>
# 출력: stdout 에 slot index (0-based)
get_slot_for_iter() {
  local iter="$1" slots_count="$2"
  # slots_count == 0 → modulo by zero 차단
  [[ "$slots_count" -gt 0 ]] || { log ERROR "get_slot_for_iter: slots_count must be > 0 (got '$slots_count')"; return 1; }
  echo $(( (iter - 1) % slots_count ))
}

# ─── write_progress: 9 인자 → 6 필드 JSON (atomic tmp + mv) ───
# Source: 02-RESEARCH § Code Examples 라인 687-700 (04-03-SUMMARY § write_progress)
write_progress() {
  local run_dir="$1" current_iter="$2" total_iter="$3" phase="$4" \
        slot="$5" failed_iters="$6" run_start_ts="$7" per_run_s="$8" cooldown_s="$9"
  local remaining=$(( total_iter - current_iter ))
  [[ $remaining -lt 0 ]] && remaining=0
  local now eta_epoch eta
  now=$(date +%s)
  eta_epoch=$(( now + remaining * (per_run_s + cooldown_s) ))
  eta=$(date -u -d "@$eta_epoch" +%FT%TZ 2>/dev/null || date -u +%FT%TZ)
  jq -n \
    --argjson ci "$current_iter" --argjson ti "$total_iter" \
    --arg phase "$phase" --arg slot "$slot" \
    --argjson fi "$failed_iters" --arg eta "$eta" \
    '{current_iter:$ci,total_iter:$ti,eta:$eta,phase:$phase,slot:$slot,failed_iters:$fi}' \
    > "${run_dir}/progress.json.tmp.$$"
  mv "${run_dir}/progress.json.tmp.$$" "${run_dir}/progress.json"
}

# ─── write_iter_meta: 6 필드 JSON (atomic tmp + mv) ───
# Schema: areas/00-contracts/README.md § iter_meta.json 스키마
# 인자: <iter_dir> <iter_num> <slot> <plan_path> <iter_start_epoch> <iter_end_epoch> <per_run_ms>
# per_run_ms 는 02-orchestration 이 Plan.json 에서 도출 (ceil(simulation_duration_ms × 1.1)).
write_iter_meta() {
  local iter_dir="$1" iter_num="$2" slot="$3" plan_path="$4" \
        iter_start_epoch="$5" iter_end_epoch="$6" per_run_ms="$7"
  jq -n \
    --argjson n "$iter_num" --arg slot "$slot" \
    --arg plan "$plan_path" --argjson s "$iter_start_epoch" \
    --argjson e "$iter_end_epoch" --argjson pr "$per_run_ms" \
    '{iter:$n,slot:$slot,plan_path:$plan,iter_start_epoch:$s,iter_end_epoch:$e,per_run_ms:$pr}' \
    > "${iter_dir}/iter_meta.json.tmp.$$"
  mv "${iter_dir}/iter_meta.json.tmp.$$" "${iter_dir}/iter_meta.json"
}

# ─── write_iter_meta_failed: reset 재시도 모두 실패 → iter 폐기 케이스 ───
# 인자: <iter_dir> <iter_num> <slot> <plan_path> <iter_start_epoch> <failed_event> <failed_http>
write_iter_meta_failed() {
  local iter_dir="$1" iter_num="$2" slot="$3" plan_path="$4" iter_start_epoch="$5"
  local failed_event="$6" failed_http="$7"
  jq -n \
    --argjson n "$iter_num" --arg slot "$slot" \
    --arg plan "$plan_path" --argjson s "$iter_start_epoch" \
    --arg ev "$failed_event" --arg http "$failed_http" \
    '{iter:$n,slot:$slot,plan_path:$plan,iter_start_epoch:$s,reset_failed:true,reset_failed_event:$ev,reset_failed_http:$http}' \
    > "${iter_dir}/iter_meta.json.tmp.$$"
  mv "${iter_dir}/iter_meta.json.tmp.$$" "${iter_dir}/iter_meta.json"
}

# ─── cleanup_on_exit: trap EXIT (정상·실패·SIGINT 모두) ───
# Source: 02-RESEARCH § Code Examples 라인 651-671 + CONTEXT § Specifics 라인 198-208
# branch.sh 의 함수에 의존 — declare -f 로 존재 확인 후 호출 (cleanup 자체 실패 방지)
# trap 안에서는 set +e + 짧은 timeout 강제 + 재진입 방지
# subshell 안에서 util.sh + branch.sh 를 source 하여
#   log/die 부재로 함수 마지막 줄이 'command not found' 1 종료 → false-positive WARN
#   을 내던 문제 수정. export -f 패턴은 Git Bash 등에서 부분 동작이라 폐기.
cleanup_on_exit() {
  local rc=$?
  # trap 안에서는 set +e + 짧은 timeout 강제
  set +e
  trap '' EXIT  # 재진입 방지

  # ssh hang 방지: timeout 으로 강제 종료 (Lock #4 fire-and-forget 신뢰성).
  # subshell 에서 util.sh+branch.sh 를 source — log/die/branch 함수 모두 복원.
  # BENCH_ROOT, GATLING_DIR, REALTICKET_DIR, VM_HOST 는 run.sh 가 이미 export.
  export run_dir 2>/dev/null || true

  if [[ "${cleanup_external_repos:-0}" == "1" ]]; then
    if declare -f rollback_untracked_overrides >/dev/null 2>&1; then
      timeout 30 bash -c '
        source "$SCRIPT_DIR/lib/util.sh"
        source "$SCRIPT_DIR/lib/branch.sh"
        rollback_untracked_overrides "${run_dir:-}"
      ' 2>/dev/null \
        || log WARN "cleanup: rollback_untracked_overrides timed out / failed"
    fi
    if declare -f restore_main_branches >/dev/null 2>&1; then
      timeout 15 bash -c '
        source "$SCRIPT_DIR/lib/util.sh"
        source "$SCRIPT_DIR/lib/branch.sh"
        restore_main_branches
      ' 2>/dev/null \
        || log WARN "cleanup: restore_main_branches timed out / failed"
    fi

    # ─── stash 안전망 ───
    # restore_main_branches 가 dev 로 복귀시킨 *후*에만 status 검사가 의미 있음
    # (메타 브랜치 위에서는 워킹트리 잔존이 commit 된 상태로 보일 수 있어 false-negative).
    # subshell + util.sh+branch.sh 두 source 는 invariant — 위배 금지.
    # 실패는 log WARN (die 금지) — run 자체는 정상 종료.
    if [[ -n "${REALTICKET_DIR:-}" && -d "$REALTICKET_DIR/.git" ]]; then
      timeout 15 bash -c '
        source "$SCRIPT_DIR/lib/util.sh"
        source "$SCRIPT_DIR/lib/branch.sh"
        if [[ -n "$(git -C "$REALTICKET_DIR" status --porcelain 2>/dev/null)" ]]; then
          run_id="$(basename "${run_dir:-unknown}")"
          log WARN "cleanup: RealTicket dev working tree dirty — auto-stashing as bench-cleanup-$run_id"
          git -C "$REALTICKET_DIR" stash push -u -m "bench-cleanup-$run_id" \
            || log WARN "cleanup: git stash push failed (manual cleanup required)"
        fi
      ' 2>/dev/null \
        || log WARN "cleanup: stash safety net timed out / failed"
    fi
  fi

  if [[ -n "${run_dir:-}" && -d "${run_dir:-/nonexistent}" ]]; then
    if [[ $rc -ne 0 ]]; then
      rm -f "${run_dir}/RUNNING"
      cat > "${run_dir}/FAILED" <<EOF
last_failed_iter=${current_iter:-?}
last_failed_slot=${current_slot:-?}
stopped_at=$(date -u +%FT%TZ)
exit_code=$rc
EOF
    fi
  fi
  exit "$rc"
}
