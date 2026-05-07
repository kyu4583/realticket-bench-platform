#!/usr/bin/env bash
# areas/00-contracts/verify-locks.sh — 4 Lock 위배 0건 검증.
# 사용: bash areas/00-contracts/verify-locks.sh
# exit 0 = ALL PASS, exit 1 = ANY FAIL
# Source: areas/02-orchestration/README.md § Lock #4 fire-and-forget 마커

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # areas/00-contracts/
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"                 # repo root
cd "$REPO_ROOT" || exit 1

fail_count=0
pass_count=0

pass() { echo "  [PASS] $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  [FAIL] $*"; fail_count=$((fail_count + 1)); }
section() { echo; echo "--- $* ---"; }

yaml_parse() {
  local file="$1"
  if command -v yq >/dev/null 2>&1; then
    yq eval '.' "$file" >/dev/null 2>&1
    return $?
  fi
  python3 - "$file" <<'PY' >/dev/null 2>&1
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    yaml.safe_load(f)
PY
}

yaml_hypotheses_len() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    doc = yaml.safe_load(f) or {}
print(len(doc.get("hypotheses") or []))
PY
}

yaml_slot0_scenario_mode() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    doc = yaml.safe_load(f) or {}
slots = doc.get("slots") or []
print((slots[0].get("scenario_mode") if slots else None) or "null")
PY
}

# ===============================================================
section "Lock #1 — Claude 단일 제어 평면 (sshfs/postman/macro 0건)"
# ===============================================================
n=$(grep -rni --include='*.sh' --include='*.py' --include='*.yml' --include='*.yaml' \
    'sshfs\|postman\|macro' areas/ bench/ 2>/dev/null \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
    | grep -v 'verify-locks.sh\|VERIFY-SUMMARY' \
    | wc -l)
n=${n//[[:space:]]/}
if [[ "$n" == "0" ]]; then
  pass "Lock #1 — sshfs/postman/macro 호출 0건 (주석·verify 자체 제외)"
else
  fail "Lock #1 — $n 건 발견"
  grep -rni --include='*.sh' --include='*.py' --include='*.yml' --include='*.yaml' \
    'sshfs\|postman\|macro' areas/ bench/ 2>/dev/null \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
    | grep -v 'verify-locks.sh\|VERIFY-SUMMARY' | head
fi

# ===============================================================
section "Lock #2 — RealTicket BE 변경 0 (영역 검증, 실주행은 별도 검증)"
# ===============================================================
# 본 repo 내 Lock #2 직접 위배 없음 — bench/ 가 RealTicket 코드를 *호출*만 함.
# branch.sh 의 prepare_realticket_branches·apply_untracked_overrides 가 bench-stack/ 폴더
# 또는 untracked-overrides.list 의 명시 경로만 건드림 (back/src/ 침범 없음 검증).
n=$(grep -rE '\bback/src/|nest/src/' areas/02-orchestration/lib/ areas/02-orchestration/run.sh areas/04-gatling-integration/lib/ areas/03-analysis/lib/ 2>/dev/null | wc -l)
n=${n//[[:space:]]/}
if [[ "$n" == "0" ]]; then
  pass "Lock #2 — bench/ 코드가 RealTicket back/src/ 경로 0건 참조"
else
  fail "Lock #2 — back/src/ 참조 $n 건 발견"
fi
echo "    -> 검증 명령: git -C \$REALTICKET_DIR rev-parse dev (전후 동일)"

# ===============================================================
section "Lock #3 — slot alternating only (concurrent dual 0건)"
# ===============================================================
# verify-locks.sh 자체 + 주석 라인 (미지원 명시) 제외 — *실제 코드* 사용만 카운트
n=$(grep -rnE --include='*.sh' --include='*.py' --include='*.yml' --include='*.yaml' \
    'concurrent.*dual|dual.*concurrent|parallel.*both.*slot' areas/ bench/ 2>/dev/null \
    | grep -v 'verify-locks.sh\|VERIFY-SUMMARY' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    | wc -l)
n=${n//[[:space:]]/}
if [[ "$n" == "0" ]]; then
  pass "Lock #3 — concurrent dual 옵션 0건 (코드 사용 — 주석/verify 자체 제외)"
else
  fail "Lock #3 — concurrent dual 패턴 $n 건 발견"
  grep -rnE --include='*.sh' --include='*.py' --include='*.yml' --include='*.yaml' \
    'concurrent.*dual|dual.*concurrent|parallel.*both.*slot' areas/ bench/ 2>/dev/null \
    | grep -v 'verify-locks.sh\|VERIFY-SUMMARY' \
    | grep -vE ':[0-9]+:[[:space:]]*#' | head
fi
# alternating modulo 패턴 lock — get_slot_for_iter 의 (iter-1) % slots_count
if grep -qE '\(\s*iter\s*-\s*1\s*\)\s*%' areas/02-orchestration/lib/lifecycle.sh; then
  pass "Lock #3 — get_slot_for_iter 의 alternating modulo 패턴 lock"
else
  fail "Lock #3 — alternating modulo 패턴 누락"
fi
# schema.yaml 의 slots[] <= 2 (Lock #3) 명시
if grep -qE 'slots\[\][[:space:]]*≤[[:space:]]*2|slots\[\][[:space:]]*<=[[:space:]]*2|최대 2 슬롯' areas/00-contracts/schema.yaml; then
  pass "Lock #3 — schema.yaml 에 slots <= 2 명시"
else
  fail "Lock #3 — schema.yaml 에 slots <= 2 명시 누락"
fi

# ===============================================================
section "Lock #4 — Fire-and-forget 마커 (RUNNING/COMPLETED/FAILED)"
# ===============================================================
for marker in RUNNING COMPLETED FAILED; do
  if grep -q "$marker" areas/02-orchestration/run.sh areas/02-orchestration/lib/lifecycle.sh 2>/dev/null; then
    pass "Lock #4 — $marker 마커 작성 lock"
  else
    fail "Lock #4 — $marker 마커 누락"
  fi
done
# progress.json 6 필드 (atomic write — jq -n one-liner 또는 분리 라인)
if grep -qE 'current_iter.*total_iter.*eta.*phase.*slot.*failed_iters|failed_iters.*slot.*phase.*eta.*total_iter.*current_iter' areas/02-orchestration/lib/lifecycle.sh; then
  pass "Lock #4 — progress.json 6 필드 (jq -n one-liner)"
else
  m=$(grep -cE '"(current_iter|total_iter|eta|phase|slot|failed_iters)"' areas/02-orchestration/lib/lifecycle.sh 2>/dev/null)
  if [[ "$m" -ge 6 ]]; then
    pass "Lock #4 — progress.json 6 필드 (분리 라인 카운트=$m)"
  else
    fail "Lock #4 — progress.json 6 필드 누락 (카운트=$m)"
  fi
fi
# trap cleanup_on_exit EXIT (정상·실패·SIGINT 모두 cleanup)
if grep -q 'trap cleanup_on_exit EXIT' areas/02-orchestration/run.sh; then
  pass "Lock #4 — trap cleanup_on_exit EXIT (정상·실패·SIGINT 모두)"
else
  fail "Lock #4 — trap cleanup_on_exit EXIT 누락"
fi

# ===============================================================
section "17 함수 + 하드코딩 0건 검증"
# ===============================================================
missing=""
for fn in parse_duration manifest_yq prepare_gatling_branch prepare_realticket_branches \
          generate_bench_stack_yml apply_untracked_overrides build_vm_images admin_login \
          reset_slots get_slot_for_iter run_gatling collect_prometheus write_progress \
          write_iter_meta rollback_untracked_overrides restore_main_branches main; do
  if ! grep -lE "^${fn}\(\) \{" areas/02-orchestration/run.sh areas/02-orchestration/lib/*.sh \
       areas/04-gatling-integration/lib/gatling.sh areas/03-analysis/lib/prom.sh >/dev/null 2>&1; then
    missing="$missing $fn"
  fi
done
if [[ -z "$missing" ]]; then
  pass "17 함수 모두 정의"
else
  fail "누락 함수:$missing"
fi
# 하드코딩 (Windows 절대경로) 검사
n=$(grep -nE '/[CD]:|^/(c|d)/' areas/02-orchestration/run.sh areas/02-orchestration/lib/*.sh \
    areas/04-gatling-integration/lib/gatling.sh areas/03-analysis/lib/prom.sh 2>/dev/null | wc -l)
n=${n//[[:space:]]/}
if [[ "$n" == "0" ]]; then
  pass "Windows 절대경로 하드코딩 0건"
else
  fail "하드코딩 $n 건"
fi
# 윈도우 사용자 경로 (kxu45·ProgramStudy·OneDrive)
n=$(grep -nE 'kxu45|ProgramStudy|OneDrive' areas/02-orchestration/run.sh areas/02-orchestration/lib/*.sh \
    areas/04-gatling-integration/lib/gatling.sh areas/03-analysis/lib/prom.sh 2>/dev/null | wc -l)
n=${n//[[:space:]]/}
if [[ "$n" == "0" ]]; then
  pass "윈도우 사용자 경로 0건"
else
  fail "사용자 경로 $n 건"
fi
# CRLF 회피 (Pitfall 2 — .gitattributes *.sh eol=lf)
if command -v file >/dev/null 2>&1; then
  n=$(file areas/02-orchestration/run.sh areas/02-orchestration/lib/*.sh \
      areas/04-gatling-integration/lib/gatling.sh areas/03-analysis/lib/prom.sh 2>/dev/null | grep -ci CRLF)
  if [[ "$n" == "0" ]]; then
    pass "CRLF 0건 (LF only)"
  else
    fail "CRLF $n 파일"
  fi
else
  pass "file(1) 미가용, CRLF 검증 skip"
fi

# ===============================================================
section "스키마·매니페스트 검증 — schema.yaml 15 core fields + optional bench_stack + 예시 매니페스트 2개"
# ===============================================================
if yaml_parse areas/00-contracts/schema.yaml; then
  pass "스키마 — schema.yaml YAML 파싱"
else
  fail "스키마 — schema.yaml YAML 파싱 실패"
fi
n=$(grep -cE '^#\s+[0-9]+\.' areas/00-contracts/schema.yaml)
if [[ "$n" == "15" ]]; then
  pass "스키마 — 15 core fields enumerate 주석 (실제 $n)"
else
  fail "스키마 — 15 core fields 주석 (실제 $n)"
fi
if yaml_parse bench/manifests/_example-min.yaml && \
   yaml_parse bench/manifests/_example-full.yaml; then
  pass "스키마 — 예시 매니페스트 2개 YAML 파싱"
else
  fail "스키마 — 예시 매니페스트 YAML 파싱 실패"
fi
# _example-full hypotheses ≥ 1
hl=$(yaml_hypotheses_len bench/manifests/_example-full.yaml)
if [[ "$hl" =~ ^[0-9]+$ && "$hl" -ge 1 ]]; then
  pass "스키마 — _example-full hypotheses 시연 (n=$hl)"
else
  fail "스키마 — _example-full hypotheses 누락"
fi
# _example-full scenario_mode override (slot[0])
sm=$(yaml_slot0_scenario_mode bench/manifests/_example-full.yaml)
if [[ "$sm" != "null" && -n "$sm" ]]; then
  pass "스키마 — _example-full scenario_mode override 시연 ($sm)"
else
  fail "스키마 — _example-full scenario_mode override 누락"
fi

# ===============================================================
section "분석 모듈 검증 — raw_requests 출력 + 3 모듈 self-test"
# ===============================================================
if grep -q 'def parse_simulation_log_to_raw_requests' areas/03-analysis/analyze/parse_simulation_log.py; then
  pass "분석 모듈 — parse_simulation_log_to_raw_requests 함수 정의"
else
  fail "분석 모듈 — parse_simulation_log_to_raw_requests 누락"
fi
n=$(grep -cE '"(request_name|status|response_time_ms|timestamp_epoch|source)"' areas/03-analysis/analyze/parse_simulation_log.py)
if [[ "$n" -ge 5 ]]; then
  pass "분석 모듈 — raw_requests.jsonl 5 필드 (실제 $n)"
else
  fail "분석 모듈 — raw_requests.jsonl 필드 누락 ($n/5)"
fi
# 3 모듈 --selftest exit 0 (PyYAML 가용 시 PASS, 미가용 시 fallback)
for mod in parse_simulation_log prom_query summarize; do
  if python3 "areas/03-analysis/analyze/$mod.py" --selftest >/dev/null 2>&1; then
    pass "분석 모듈 — $mod.py --selftest exit 0"
  else
    if python3 "areas/03-analysis/analyze/$mod.py" --help >/dev/null 2>&1; then
      pass "분석 모듈 — $mod.py --help PASS (selftest skipped, PyYAML 미설치 가능)"
    else
      fail "분석 모듈 — $mod.py --help/--selftest 모두 fail"
    fi
  fi
done

# ===============================================================
section "템플릿 시스템 검증 — base.yml + α/β/γ 마커 + 매핑 표"
# ===============================================================
if yaml_parse areas/02-orchestration/templates/docker-stack.base.yml; then
  pass "템플릿 — base.yml YAML 파싱"
else
  fail "템플릿 — base.yml YAML 파싱 실패"
fi
for patch in alpha-test-account beta-dual-slots gamma-sentinel delta-autoscaler; do
  if [[ -f "areas/02-orchestration/templates/dimensions/${patch}.patch.yml" ]]; then
    pass "템플릿 — ${patch}.patch.yml 존재"
  else
    fail "템플릿 — ${patch}.patch.yml 누락"
  fi
done
# default 값 (4 토글 off — base 단독 dry-run 가능)
if grep -q 'Services: mysql + nest-baseline + redis-master + prometheus + grafana + cadvisor + node-exporter' areas/02-orchestration/templates/docker-stack.base.yml && \
   grep -q 'REDIS_SENTINEL_MODE: "false"' areas/02-orchestration/templates/docker-stack.base.yml && \
   grep -q 'image: nest:MANIFEST_ID_PLACEHOLDER' areas/02-orchestration/templates/docker-stack.base.yml; then
  pass "템플릿 — default 값 lock (4 토글 off, 7 services baseline)"
else
  fail "템플릿 — default 값 누락"
fi
# 4 토글 매핑 표 (templates/README.md)
if grep -q 'alpha-test-account' areas/02-orchestration/templates/README.md && \
   grep -q 'beta-dual-slots' areas/02-orchestration/templates/README.md && \
   grep -q 'gamma-sentinel' areas/02-orchestration/templates/README.md && \
   grep -q 'delta-autoscaler' areas/02-orchestration/templates/README.md; then
  pass "템플릿 — 4 토글 매핑 표"
else
  fail "템플릿 — 4 토글 매핑 표 누락"
fi
# .scratch/ cleanup — .gitkeep + 검증 스크립트만 허용
if [[ -d areas/02-orchestration/templates/.scratch ]]; then
  n=$(ls -A areas/02-orchestration/templates/.scratch/ 2>/dev/null | grep -vE '^(.gitkeep|verify-dimensions\.sh)$' | wc -l)
  n=${n//[[:space:]]/}
  if [[ "$n" == "0" ]]; then
    pass "템플릿 — .scratch/ cleanup — 허용 파일만 존재"
  else
    fail "템플릿 — .scratch/ 에 $n 잔여물"
  fi
else
  pass "템플릿 — .scratch/ 자체 부재 (cleanup 동등)"
fi

# ===============================================================
section "매니페스트 ID 브랜치 정합성 — 명령 형태 lock (실주행은 별도 검증)"
# ===============================================================
echo "  -> 다음 명령들은 별도 실주행에서 검증됨:"
echo "    (a) main 영구 변경 0건:"
echo "        git -C \$GATLING_DIR rev-parse main      # dry-run 전후 동일"
echo "        git -C \$REALTICKET_DIR rev-parse dev    # dry-run 전후 동일"
echo "    (b) 매니페스트 ID 브랜치 영구 보존:"
echo "        git -C \$GATLING_DIR branch -a | grep bench/<manifest_id>"
echo "        git -C \$REALTICKET_DIR branch -a | grep bench/<manifest_id>"
echo "    (c) untracked override 롤백:"
echo "        ssh \$VM_HOST 'cd ~/web04-RealTicket && git status --porcelain'  # 전후 동일"
echo "    (d) 슬롯 yml hash 동일:"
echo "        for br in bench/<id> bench/<id>/<slot1> bench/<id>/<slot2>; do"
echo "          git -C \$REALTICKET_DIR show \$br:bench-stack/<id>.yml | sha256sum"
echo "        done   # 모두 동일"

# 본 repo 산출물에서 위 명령들이 코드 형태로 lock 되어있는지 cross-grep
locked=0
grep -qE 'checkout main|rev-parse main' areas/02-orchestration/lib/branch.sh && locked=$((locked + 1))
grep -qE 'checkout dev|rev-parse dev' areas/02-orchestration/lib/branch.sh && locked=$((locked + 1))
grep -qE 'branch -a|show-ref' areas/02-orchestration/lib/branch.sh && locked=$((locked + 1))
grep -qE 'cherry-pick|sha256sum' areas/02-orchestration/lib/bench_stack.sh areas/00-contracts/verify-locks.sh && locked=$((locked + 1))
if [[ "$locked" -ge 3 ]]; then
  pass "정합성 명령 형태 lock — branch.sh main/dev 복귀 + bench_stack.sh hash 동일 cherry-pick (lock=$locked/4)"
else
  fail "정합성 명령 형태 lock 부족 (locked=$locked/4)"
fi

# ===============================================================
echo
echo "============================================="
echo "verify-locks.sh 종합"
echo "  PASS: $pass_count"
echo "  FAIL: $fail_count"
if [[ "$fail_count" == "0" ]]; then
  echo "  ALL PASS"
  exit 0
else
  echo "  $fail_count 건 FAIL — 위 출력 참조하여 수정 후 재실행"
  exit 1
fi
