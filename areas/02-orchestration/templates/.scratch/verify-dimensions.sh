#!/usr/bin/env bash
# areas/02-orchestration/templates/.scratch/verify-dimensions.sh — 4 차원 토글 조합 정적 검증
# Source: areas/02-orchestration/README.md § 이미지 swap·stack restart 절차
#
# 본 스크립트는 generate_bench_stack_yml 의 *동작 단위* 정적 검증.
# 실 VM deploy 검증은 self dry-run 위임.
#
# 4 단계:
#   [1/4] base.yml 단독 syntax + services 7개
#   [2/4] 16 조합 (2^4) yq merge + yq syntax + docker compose config 통과 + expected services 수
#   [3/4] commit 명령 격리 검증 — areas/02-orchestration/lib/branch.sh + lifecycle.sh 의 commit 명령 0건
#   [4/4] areas/02-orchestration/lib/bench_stack.sh 정적 (|| true 0건, sed 마커 0건, --no-verify 2건, yq merge ≥1, die ≥4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

# CLI prereq 명시화. docker / yq 미설치 시 의외 실패 메시지 회피.
# verify 본문이 docker compose config + yq eval 양쪽 모두 의존하므로 진입부 fail-fast.
command -v docker >/dev/null 2>&1 || { echo "FAIL: docker CLI required for verify-dimensions"; exit 1; }
command -v yq     >/dev/null 2>&1 || { echo "FAIL: yq CLI required for verify-dimensions";     exit 1; }

# /tmp 하드코딩 제거 (Windows 비호환 환경 의존 + cleanup 누락 회피).
# mktemp -d 로 임시 디렉토리 확보 + trap 으로 종료 시 자동 cleanup (정상·실패·SIGINT 모두).
TMPDIR_VERIFY=$(mktemp -d) || { echo "FAIL: mktemp -d"; exit 1; }
trap 'rm -rf "$TMPDIR_VERIFY"' EXIT

BASE="areas/02-orchestration/templates/docker-stack.base.yml"
DIM="areas/02-orchestration/templates/dimensions"

declare -A PATCHES=(
  [a]="$DIM/alpha-test-account.patch.yml"
  [b]="$DIM/beta-dual-slots.patch.yml"
  [g]="$DIM/gamma-sentinel.patch.yml"
  [d]="$DIM/delta-autoscaler.patch.yml"
)

# Ordering — generate_bench_stack_yml 의 enumeration 순서 (α → β → γ → δ)
ORDER=(a b g d)

# Expected services 수 (rev 2 lock — α image override 만, +0 service)
# 빈 combo (base 단독) 는 "base" 키로 매핑 — bash assoc array 의 빈 string 키 거부 회피
declare -A EXPECTED=(
  ["base"]="7"
  ["a"]="7"  ["b"]="8"  ["g"]="11" ["d"]="8"
  ["ab"]="8" ["ag"]="11" ["ad"]="8"
  ["bg"]="12" ["bd"]="9" ["gd"]="12"
  ["abg"]="12" ["abd"]="9" ["agd"]="12" ["bgd"]="13"
  ["abgd"]="13"
)

resolve_files() {
  local combo="$1"
  local files=("$BASE")
  local ch
  for ch in "${ORDER[@]}"; do
    case "$combo" in
      *$ch*) files+=("${PATCHES[$ch]}") ;;
    esac
  done
  printf '%s\n' "${files[@]}"
}

# run_compose_config <yml-path> — docker compose config --quiet 실행하고 stderr 에서
# 허용 warning (version obsolete, level=warning prefix) 만 있으면 통과, 그 외 출력 또는
# RC≠0 시 실패. set -e + pipefail 호환을 위해 파이프라인 회피, 변수에 캡처해 평가.
run_compose_config() {
  local yml="$1"
  local stderr filtered rc
  stderr=$(docker compose -f "$yml" config --quiet 2>&1) && rc=0 || rc=$?
  filtered=$(printf '%s\n' "$stderr" \
    | grep -v 'attribute .version. is obsolete' \
    | grep -v 'level=warning' \
    | grep -v '^$' \
    || true)
  [[ "$rc" == "0" && -z "$filtered" ]]
}

echo "[1/4] base.yml 단독 syntax + services 7"
yq eval '.' "$BASE" >/dev/null || { echo "FAIL: base.yml yq syntax"; exit 1; }
run_compose_config "$BASE" \
  || { echo "FAIL: docker compose config (base 단독)"; exit 1; }
SVC=$(yq eval '.services | keys | length' "$BASE")
[[ "$SVC" == "7" ]] || { echo "FAIL: base services count = $SVC (expected 7)"; exit 1; }
echo "  ✓ base 단독 (services=$SVC)"

echo "[2/4] 16 조합 (2^4) yq merge + yq syntax + docker compose config + expected services 수"
combos=("" "a" "b" "g" "d" "ab" "ag" "ad" "bg" "bd" "gd" "abg" "abd" "agd" "bgd" "abgd")
PASS=0
for c in "${combos[@]}"; do
  mapfile -t files < <(resolve_files "$c")
  out="$TMPDIR_VERIFY/bench-stack-${c:-base}.yml"

  yq eval-all '. as $i ireduce ({}; . *+ $i)' "${files[@]}" \
    | sed "s|MANIFEST_ID_PLACEHOLDER|verify-${c:-base}|g" \
    | sed "s|CANDIDATE_IMAGE_PLACEHOLDER|verify-${c:-base}-candidate|g" \
    > "$out" \
    || { echo "FAIL: combo=${c:-empty} yq merge"; exit 1; }
  test -s "$out" || { echo "FAIL: combo=${c:-empty} 빈 yml"; exit 1; }

  yq eval '.' "$out" >/dev/null \
    || { echo "FAIL: combo=${c:-empty} yq syntax (post-merge)"; exit 1; }

  run_compose_config "$out" \
    || { echo "FAIL: combo=${c:-empty} docker compose config"; exit 1; }

  SVC=$(yq eval '.services | keys | length' "$out")
  KEY="${c:-base}"
  EXP="${EXPECTED[$KEY]}"
  [[ "$SVC" == "$EXP" ]] || { echo "FAIL: combo=${c:-empty} services=$SVC (expected $EXP)"; exit 1; }

  # γ array concat 직접 assertion (yq `*+` array concat 동작 회귀 검출 강화).
  # γ 활성 조합 (g, ag, bg, gd, abg, agd, bgd, abgd): nest-baseline.depends_on length == 5
  #   (base [mysql, redis-master] 2 + γ [sentinel-1, -2, -3] 3 → concat = 5)
  # γ 비활성 조합: length == 2 (base 그대로)
  DEP=$(yq eval '.services["nest-baseline"].depends_on | length' "$out")
  case "$KEY" in
    *g*) EXP_DEP=5 ;;
    *)   EXP_DEP=2 ;;
  esac
  [[ "$DEP" == "$EXP_DEP" ]] \
    || { echo "FAIL: combo=${c:-empty} nest-baseline.depends_on length=$DEP (expected $EXP_DEP)"; exit 1; }

  echo "  ✓ combo=${c:-empty} (services=$SVC, depends_on=$DEP, file=$out)"
  PASS=$((PASS + 1))
done
[[ "$PASS" == "16" ]] || { echo "FAIL: pass count=$PASS (expected 16)"; exit 1; }
echo "  All 16 combos passed (services count lock 일치)."

echo "[3/4] commit 명령 격리 검증 — areas/02-orchestration/lib/branch.sh + lifecycle.sh commit 명령 0건"
# 파일 존재 선행 검증 — `|| true` 가 RC=2 (no such file) 를 흡수해 silent PASS 되는 회귀 차단
for f in areas/02-orchestration/lib/branch.sh areas/02-orchestration/lib/lifecycle.sh; do
  [[ -f "$f" ]] || { echo "FAIL: invariant target missing: $f"; exit 1; }
done
B=$(grep -nE 'git( -C [^ ]+)? commit' areas/02-orchestration/lib/branch.sh || true)
[[ -z "$B" ]] || { echo "FAIL: branch.sh commit 명령 등장 (격리 위배):"; echo "$B"; exit 1; }
L=$(grep -nE 'git( -C [^ ]+)? commit' areas/02-orchestration/lib/lifecycle.sh || true)
[[ -z "$L" ]] || { echo "FAIL: lifecycle.sh commit 명령 등장 (Phase 4 invariant 위배):"; echo "$L"; exit 1; }
echo "  ✓ branch.sh + lifecycle.sh commit 명령 0건"

echo "[4/4] areas/02-orchestration/lib/bench_stack.sh 정적 (Plan 02 산출 invariant)"
T="areas/02-orchestration/lib/bench_stack.sh"
TRUE_C=$(grep -c '|| true' "$T" || true)
[[ "$TRUE_C" == "0" ]] || { echo "FAIL: || true count=$TRUE_C (fail-fast 위배)"; exit 1; }

SED_C=$(grep -cE 'sed -i.*CHANGE-' "$T" || true)
[[ "$SED_C" == "0" ]] || { echo "FAIL: 옛 sed CHANGE- 마커 count=$SED_C (폐기된 방식)"; exit 1; }

NV_C=$(grep -c -- '--no-verify' "$T" || true)
[[ "$NV_C" == "2" ]] || { echo "FAIL: --no-verify count=$NV_C (expected 2: commit + cherry-pick)"; exit 1; }

YQ_C=$(grep -cE 'yq eval-all.*ireduce' "$T" || true)
[[ "$YQ_C" -ge "1" ]] || { echo "FAIL: yq merge loop count=$YQ_C (expected ≥1)"; exit 1; }

DIE_C=$(grep -cE '\|\| die|die "' "$T" || true)
[[ "$DIE_C" -ge "4" ]] || { echo "FAIL: die count=$DIE_C (expected ≥4)"; exit 1; }

bash -n "$T" || { echo "FAIL: bash syntax"; exit 1; }
echo "  ✓ bench_stack.sh 정적 (|| true=$TRUE_C, sed=$SED_C, --no-verify=$NV_C, yq=$YQ_C, die=$DIE_C, bash -n OK)"

echo ""
echo "ALL CHECKS PASSED — 템플릿 시스템 정적 정합성 검증 완료."
