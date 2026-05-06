#!/usr/bin/env bash
# areas/02-orchestration/lib/bench_stack.sh — base + dimensions/{4 patch} → bench-stack/<id>.yml
# Source: areas/02-orchestration/README.md § 이미지 swap·stack restart 절차 + areas/05-realticket-integration/README.md § bench-stack yml 컨벤션
#
# Phase 5 재작성 (rev 2 — 2026-05-04):
#   - 옛 sed 마커 시스템 폐기 → 4 토글 → 활성 patch → 단일 yq merge loop
#   - git commit + cherry-pick 두 위치 모두 husky bypass 인라인 플래그
#   - silent-mask 폐기 → die fail-fast
#   - 함수 시그니처 (manifest_id, manifest_path 2 인자 고정) / areas/02-orchestration/run.sh 호출 측 무변동 (Phase 5 boundary 보호)
#   - nest 빌드 = 모든 차원 조합에서 back/Dockerfile.dev-in-local (base.yml 의 nest-baseline.build 가 lock)

# generate_bench_stack_yml: base + 활성 patch yq merge → 메타 브랜치 commit + 슬롯 cherry-pick
# 인자: <manifest_id> <manifest_path>  ← 2 인자 고정. 슬롯은 함수 내부에서 manifest_yq 추출 (run.sh:87 호출 측 무변동)
# 4 토글: bench_stack.{alpha_test_account, beta_dual_slots, gamma_sentinel, delta_autoscaler}
#         default = false (측정 의도가 토글 활성을 명시 요구하지 않으면 disabled)
generate_bench_stack_yml() {
  local manifest_id="$1" manifest="$2"

  # VM 자격증명 환경변수 부재 시 die fail-fast.
  # base.yml 의 `${VM_REALTICKET_*}` 가 stack deploy 시점 host shell 에서 expand 되므로,
  # bench-stack/<id>.yml 생성 시점에 부재 검출해야 deploy 단계의 silent 빈 비밀번호 사고 차단.
  # 동기화 메커니즘 자체는 m1 범위 밖 — 본 die 는 *변수 컨벤션 lock* 의 fail-fast 역할.
  local _vm_var
  for _vm_var in VM_REALTICKET_MYSQL_ROOT_PASSWORD VM_REALTICKET_MYSQL_PASSWORD VM_REALTICKET_GRAFANA_ADMIN_PASSWORD; do
    [[ -n "${!_vm_var:-}" ]] || die "환경변수 미설정: $_vm_var (areas/06-vm-environment/.env.vm.example 참조)"
  done

  # 슬롯 추출 (함수 내부 — run.sh:87 호출 측 2 인자 invariant 보호)
  local slots_str
  slots_str=$(manifest_yq 'slots[].name' "$manifest")
  local -a slots=()
  if [[ -n "$slots_str" && "$slots_str" != "null" ]]; then
    while IFS= read -r s; do [[ -n "$s" ]] && slots+=("$s"); done <<< "$slots_str"
  fi

  local base="$(dirname "${BASH_SOURCE[0]}")/../templates/docker-stack.base.yml"
  local dim_dir="$(dirname "${BASH_SOURCE[0]}")/../templates/dimensions"
  [[ -f "$base" ]] || die "base.yml not found: $base"

  # 1. 매니페스트 4 토글 추출 (default = false)
  local alpha beta gamma delta
  alpha=$(manifest_yq 'bench_stack.alpha_test_account' "$manifest")
  beta=$(manifest_yq  'bench_stack.beta_dual_slots'    "$manifest")
  gamma=$(manifest_yq 'bench_stack.gamma_sentinel'     "$manifest")
  delta=$(manifest_yq 'bench_stack.delta_autoscaler'   "$manifest")
  [[ "$alpha" == "null" || -z "$alpha" ]] && alpha="false"
  [[ "$beta"  == "null" || -z "$beta"  ]] && beta="false"
  [[ "$gamma" == "null" || -z "$gamma" ]] && gamma="false"
  [[ "$delta" == "null" || -z "$delta" ]] && delta="false"

  # 1.5. boolean enum 강제 — yes/True/1 등 변형 silent disabled 방지 (fail-fast)
  local _tname _tval
  for _tname in alpha beta gamma delta; do
    _tval="${!_tname}"
    case "$_tval" in
      true|false) ;;
      *) die "bench_stack.${_tname}_* must be boolean true|false, got: '$_tval'" ;;
    esac
  done

  # 2. 활성 patch enumeration (단일 yq merge loop 입력)
  local patches=("$base")
  [[ "$alpha" == "true" ]] && patches+=("$dim_dir/alpha-test-account.patch.yml")
  [[ "$beta"  == "true" ]] && patches+=("$dim_dir/beta-dual-slots.patch.yml")
  [[ "$gamma" == "true" ]] && patches+=("$dim_dir/gamma-sentinel.patch.yml")
  [[ "$delta" == "true" ]] && patches+=("$dim_dir/delta-autoscaler.patch.yml")

  # 3. patch 존재 검증 (fail-fast — branch.sh die 패턴 일관)
  local p
  for p in "${patches[@]}"; do
    [[ -f "$p" ]] || die "patch fragment not found: $p"
  done

  # 4. 단일 yq merge + MANIFEST_ID/CANDIDATE_IMAGE placeholder sed 1회 후처리
  #    임시파일 + RC 분리 — 호출자 pipefail 가정에 의존하지 않는 fail-fast
  local out_dir="$REALTICKET_DIR/bench-stack"
  local out_file="$out_dir/$manifest_id.yml"
  mkdir -p "$out_dir"
  local tmp_yml
  tmp_yml=$(mktemp) || die "mktemp failed for $manifest_id"
  yq eval-all '. as $item ireduce ({}; . *+ $item)' "${patches[@]}" > "$tmp_yml" \
    || { rm -f "$tmp_yml"; die "yq merge failed for $manifest_id"; }
  [[ -s "$tmp_yml" ]] || { rm -f "$tmp_yml"; die "yq merge produced empty output for $manifest_id"; }
  sed -e "s|MANIFEST_ID_PLACEHOLDER|$manifest_id|g" \
      -e "s|CANDIDATE_IMAGE_PLACEHOLDER|$manifest_id-candidate|g" \
      "$tmp_yml" > "$out_file" \
    || { rm -f "$tmp_yml"; die "sed substitution failed for $manifest_id"; }
  rm -f "$tmp_yml"
  [[ -s "$out_file" ]] || die "post-sed produced empty file for $manifest_id"

  # 5. 메타 브랜치 commit (husky bypass + fail-fast)
  #    재실행 시 동일 yml 이미 commit 된 경우 "nothing to commit" → skip (정상, die X)
  git -C "$REALTICKET_DIR" add "bench-stack/$manifest_id.yml" \
    || die "bench-stack add failed for $manifest_id"
  if git -C "$REALTICKET_DIR" diff --cached --quiet; then
    log INFO "generate_bench_stack_yml: bench-stack/$manifest_id.yml unchanged (re-run, skip commit)"
  else
    git -C "$REALTICKET_DIR" commit --no-verify \
      -m "bench: $manifest_id — bench-stack yml (α=$alpha β=$beta γ=$gamma δ=$delta)" \
      || die "bench-stack commit failed for $manifest_id"
  fi

  # 6. 슬롯 cherry-pick (fail-fast + husky bypass 인라인)
  if [[ "${#slots[@]}" -ge 2 ]]; then
    local last_commit
    last_commit=$(git -C "$REALTICKET_DIR" rev-parse HEAD) \
      || die "rev-parse HEAD failed after bench-stack commit for $manifest_id"
    local slot
    for slot in "${slots[@]}"; do
      [[ -z "$slot" ]] && continue
      git -C "$REALTICKET_DIR" checkout "bench/$manifest_id/$slot" \
        || die "checkout bench/$manifest_id/$slot failed"
      git -C "$REALTICKET_DIR" cherry-pick --no-verify "$last_commit" \
        || die "cherry-pick failed for slot=$slot manifest_id=$manifest_id"
    done
    # 메타 브랜치 복귀
    git -C "$REALTICKET_DIR" checkout "bench/$manifest_id" \
      || die "checkout back to bench/$manifest_id failed"
  fi

  log INFO "generate_bench_stack_yml: $out_file (α=$alpha β=$beta γ=$gamma δ=$delta, patches=${#patches[@]})"
}
