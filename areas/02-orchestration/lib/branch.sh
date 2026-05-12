#!/usr/bin/env bash
# areas/02-orchestration/lib/branch.sh — 매니페스트 ID 브랜치 라이프사이클
# Source: areas/04-gatling-integration/README.md § prepare_gatling_branch() 수행 순서
# Source: areas/05-realticket-integration/README.md § prepare_realticket_branches() 수행 순서 + § 불변 조건

# ─── prepare_gatling_branch: gatling repo bench/<manifest_id> 분기 ───
# 인자: <manifest_id>
prepare_gatling_branch() {
  local manifest_id="$1"
  local base_ref="${GATLING_BASE_REF:-origin/main}"
  if [[ "${GATLING_LOCAL_ONLY:-0}" == "1" ]]; then
    if git -C "$GATLING_DIR" show-ref --verify --quiet "refs/heads/bench/$manifest_id"; then
      git -C "$GATLING_DIR" checkout "bench/$manifest_id"
    else
      git -C "$GATLING_DIR" checkout -b "bench/$manifest_id" "$base_ref"
    fi
    log INFO "prepare_gatling_branch: local-only gatling bench/$manifest_id (base=$base_ref, push skipped)"
    return 0
  fi

  git -C "$GATLING_DIR" fetch origin
  if git -C "$GATLING_DIR" show-ref --verify --quiet "refs/heads/bench/$manifest_id"; then
    git -C "$GATLING_DIR" checkout "bench/$manifest_id"
  else
    git -C "$GATLING_DIR" checkout -b "bench/$manifest_id" origin/main
  fi
  # ─── origin push + rename-then-push 충돌 처리 ───
  if git -C "$GATLING_DIR" ls-remote --heads --exit-code origin "bench/$manifest_id" >/dev/null 2>&1; then
    # origin 에 동명 ref 존재 → fetch + sha 캡처 + 새 이름 보존 push + force push
    git -C "$GATLING_DIR" fetch origin "+refs/heads/bench/$manifest_id:refs/remotes/origin/bench/$manifest_id" \
      || die "prepare_gatling_branch: origin fetch failed for bench/$manifest_id"
    local rsha
    rsha=$(git -C "$GATLING_DIR" rev-parse "origin/bench/$manifest_id")
    local utc_ts
    utc_ts=$(date -u +%Y%m%d-%H%M%S)
    git -C "$GATLING_DIR" push origin "${rsha}:refs/heads/bench/${manifest_id}-before-${utc_ts}" \
      || die "prepare_gatling_branch: origin rename-push failed (bench/${manifest_id}-before-${utc_ts})"
    git -C "$GATLING_DIR" push -f -u origin "bench/$manifest_id" \
      || die "prepare_gatling_branch: origin force push failed for bench/$manifest_id"
  else
    # origin 에 미존재 → 단순 새 push
    git -C "$GATLING_DIR" push -u origin "bench/$manifest_id" \
      || die "prepare_gatling_branch: origin push failed for bench/$manifest_id"
  fi
  log INFO "prepare_gatling_branch: gatling → bench/$manifest_id"
}

# ─── prepare_realticket_branches: 메타 + 슬롯 브랜치 분기 ───
# 인자: <manifest_id> <slot_names...>
# 단일 슬롯 시 메타만, 슬롯 ≥ 2 시 슬롯 브랜치 N개 추가
prepare_realticket_branches() {
  local manifest_id="$1"
  shift
  local slot_names=("$@")
  local meta_br="bench/$manifest_id/meta"
  git -C "$REALTICKET_DIR" fetch origin
  # prometheus.yml stat-cache dirty 방지: yq가 동일 내용을 재기록하면 mtime만 갱신돼
  # git이 "modified"로 판정해 checkout을 거부한다. 내용이 같으므로 restore로 무해하게 해소.
  git -C "$REALTICKET_DIR" checkout -- "prometheus/prometheus.yml" 2>/dev/null || true
  # 메타 브랜치 (항상 1개)
  if git -C "$REALTICKET_DIR" show-ref --verify --quiet "refs/heads/$meta_br"; then
    git -C "$REALTICKET_DIR" checkout "$meta_br"
  else
    git -C "$REALTICKET_DIR" checkout -b "$meta_br" origin/dev
  fi
  # 슬롯 브랜치 (슬롯 ≥ 2 시)
  if [[ ${#slot_names[@]} -ge 2 ]]; then
    local slot_idx=0
    for slot in "${slot_names[@]}"; do
      [[ -z "$slot" ]] && { slot_idx=$((slot_idx+1)); continue; }
      local br="bench/$manifest_id/$slot"
      # SLOT_SOURCE_BRANCH[$slot_idx] 가 있으면 그 브랜치를 기점으로 분기
      local src_branch="${SLOT_SOURCE_BRANCH[$slot_idx]:-}"
      if git -C "$REALTICKET_DIR" show-ref --verify --quiet "refs/heads/$br"; then
        git -C "$REALTICKET_DIR" checkout "$br"
      elif [[ -n "$src_branch" ]]; then
        git -C "$REALTICKET_DIR" checkout -b "$br" "$src_branch" \
          || die "prepare_realticket_branches: checkout -b $br from $src_branch failed"
      else
        git -C "$REALTICKET_DIR" checkout -b "$br" "$meta_br"
      fi
      slot_idx=$((slot_idx+1))
    done
    # 메타 브랜치로 복귀 (yml commit 은 generate_bench_stack_yml 가 메타에서)
    git -C "$REALTICKET_DIR" checkout "$meta_br"
  fi
  log INFO "prepare_realticket_branches: meta + ${#slot_names[@]} slot branch(es) prepared"
}

ensure_realticket_prometheus_scrape_interval() {
  local manifest_id="$1"
  shift
  local slot_names=("$@")
  local target_interval="${REALTICKET_PROMETHEUS_SCRAPE_INTERVAL:-1s}"
  local prometheus_config="prometheus/prometheus.yml"
  local branches=("bench/$manifest_id/meta")

  [[ "$target_interval" =~ ^[0-9]+(ms|s|m|h)$ ]] \
    || die "ensure_realticket_prometheus_scrape_interval: invalid target interval '$target_interval'"

  if [[ ${#slot_names[@]} -ge 2 ]]; then
    local slot
    for slot in "${slot_names[@]}"; do
      [[ -z "$slot" ]] && continue
      branches+=("bench/$manifest_id/$slot")
    done
  fi

  local br
  for br in "${branches[@]}"; do
    git -C "$REALTICKET_DIR" checkout "$br" \
      || die "ensure_realticket_prometheus_scrape_interval: checkout failed for $br"

    [[ -f "$REALTICKET_DIR/$prometheus_config" ]] \
      || die "ensure_realticket_prometheus_scrape_interval: missing $prometheus_config on $br"

    if ! git -C "$REALTICKET_DIR" diff --quiet -- "$prometheus_config" \
        || ! git -C "$REALTICKET_DIR" diff --cached --quiet -- "$prometheus_config"; then
      die "ensure_realticket_prometheus_scrape_interval: $prometheus_config has pre-existing local changes on $br"
    fi

    # nest-app dns 타깃을 슬롯별 실제 서비스명으로 교체 (tasks.nest → tasks.nest-<slot>)
    local _nest_names="" _sep=""
    for _slot in "${slot_names[@]}"; do
      [[ -z "$_slot" ]] && continue
      _nest_names+="${_sep}\"tasks.nest-${_slot}\""
      _sep=","
    done
    [[ -z "$_nest_names" ]] && _nest_names='"tasks.nest-baseline"'

    yq -i \
      "(.global.scrape_interval) = \"$target_interval\" | del(.scrape_configs[].scrape_interval) | (.scrape_configs[] | select(.job_name == \"nest-app\") | .dns_sd_configs[0].names) = [${_nest_names}]" \
      "$REALTICKET_DIR/$prometheus_config" \
      || die "ensure_realticket_prometheus_scrape_interval: yq update failed for $br"

    if git -C "$REALTICKET_DIR" diff --quiet -- "$prometheus_config"; then
      log INFO "ensure_realticket_prometheus_scrape_interval: $br no change (already up-to-date)"
      # yq가 LF로 재기록해 Windows CRLF dirty 상태가 될 수 있으므로 git 버전으로 복원
      git -C "$REALTICKET_DIR" checkout -- "$prometheus_config" 2>/dev/null || true
    else
      git -C "$REALTICKET_DIR" add "$prometheus_config" \
        || die "ensure_realticket_prometheus_scrape_interval: add failed for $br"
      git -C "$REALTICKET_DIR" commit --no-verify \
        -m "bench: prometheus scrape_interval=${target_interval}, nest targets=[${_nest_names}]" \
        || die "ensure_realticket_prometheus_scrape_interval: commit failed for $br"
    fi
  done

  git -C "$REALTICKET_DIR" checkout "bench/$manifest_id/meta" \
    || die "ensure_realticket_prometheus_scrape_interval: checkout back to meta failed"
  log INFO "ensure_realticket_prometheus_scrape_interval: ${#branches[@]} branch(es) checked"
}

# ─── apply_untracked_overrides: untracked 파일 VM 적용 ───
# 인자: <manifest_id> <run_dir>
# m1 self dry-run 단계에서는 untracked override 가 없으므로 빈 list 만 작성.
# 실제 운영 매니페스트는 schema 의 untracked_overrides:[] 를 enumerate 하여 scp/heredoc 으로 적용.
apply_untracked_overrides() {
  local manifest_id="$1" run_dir="$2"
  local list_file="$run_dir/untracked-overrides.list"
  : > "$list_file"
  log INFO "apply_untracked_overrides: list_file=$list_file (empty for m1 self dry-run)"
}

# ─── rollback_untracked_overrides: untracked-overrides.list 의 각 경로만 복구 ───
# Source: 05 README § untracked 라인 102-111 (다른 VM 환경 변경은 절대 건드리지 않음)
# 인자: <run_dir>
rollback_untracked_overrides() {
  local run_dir="${1:-}"
  [[ -n "$run_dir" && -f "$run_dir/untracked-overrides.list" ]] || return 0
  while IFS= read -r remote_path; do
    [[ -z "$remote_path" ]] && continue
    # 추적 파일이면 git checkout, 신규 파일이면 rm — 그 경로만
    # ConnectTimeout + BatchMode 명시 — VM 단절 시 60s+ hang 방지
    # remote_path 를 bash -s 인자로 전달 + VM 측 화이트리스트 검증 (path injection 차단)
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$VM_HOST" \
      bash -s -- "$remote_path" <<'REMOTE'
      cd ~/web04-RealTicket
      path="$1"
      [[ "$path" =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "invalid remote_path: $path" >&2; exit 1; }
      git checkout -- "$path" 2>/dev/null || rm -f "$path"
REMOTE

  done < "$run_dir/untracked-overrides.list"
  log INFO "rollback_untracked_overrides: completed for $run_dir"
}

# ─── restore_main_branches: 두 repo 모두 main/dev 복귀 (브랜치 삭제 X) ───
# 브랜치 영구 보존
restore_main_branches() {
  if [[ -n "${GATLING_DIR:-}" && -d "$GATLING_DIR/.git" ]]; then
    git -C "$GATLING_DIR" checkout main 2>/dev/null || true
  fi
  if [[ -n "${REALTICKET_DIR:-}" && -d "$REALTICKET_DIR/.git" ]]; then
    git -C "$REALTICKET_DIR" checkout dev 2>/dev/null || true
  fi
  log INFO "restore_main_branches: gatling→main, realticket→dev (branches preserved)"
}

# ─── push_realticket_branches_to_origin: 메타 + 슬롯 브랜치 origin push ───
# 인자: <manifest_id> <slot_names...>
# 호출 시점: areas/02-orchestration/run.sh main flow 의 generate_bench_stack_yml 직후 (메타 yml commit + 슬롯 cherry-pick 완료 후)
# 옛 origin 브랜치는 bench/<id>-before-<YYYYMMDD-HHMMSS> 로 rename 보관 후 force push.
push_realticket_branches_to_origin() {
  local manifest_id="$1"
  shift
  local slot_names=("$@")
  git -C "$REALTICKET_DIR" fetch origin
  ensure_realticket_prometheus_scrape_interval "$manifest_id" "${slot_names[@]}"
  _push_one_realticket_branch "bench/$manifest_id/meta"
  if [[ ${#slot_names[@]} -ge 2 ]]; then
    for slot in "${slot_names[@]}"; do
      [[ -z "$slot" ]] && continue
      _push_one_realticket_branch "bench/$manifest_id/$slot"
    done
  fi
  log INFO "push_realticket_branches_to_origin: meta + ${#slot_names[@]} slot branch(es) pushed to origin"
}

# ─── _push_one_realticket_branch: 단일 ref 의 B-2 rename-then-push (helper 내부) ───
# 인자: <full_branch_name>  (예: bench/<id> 또는 bench/<id>/<slot>)
_push_one_realticket_branch() {
  local br="$1"
  local local_sha
  local_sha=$(git -C "$REALTICKET_DIR" rev-parse "$br")
  if git -C "$REALTICKET_DIR" ls-remote --heads --exit-code origin "$br" >/dev/null 2>&1; then
    git -C "$REALTICKET_DIR" fetch origin "+refs/heads/${br}:refs/remotes/origin/${br}" \
      || die "push_realticket_branches_to_origin: origin fetch failed for $br"
    local rsha
    rsha=$(git -C "$REALTICKET_DIR" rev-parse "origin/$br")
    # 동일 SHA면 skip — 재실행 시 불필요한 rename 브랜치 생성 방지
    if [[ "$local_sha" == "$rsha" ]]; then
      log INFO "_push_one_realticket_branch: $br already up-to-date — skipping"
      return 0
    fi
    local utc_ts
    utc_ts=$(date -u +%Y%m%d-%H%M%S)
    git -C "$REALTICKET_DIR" push origin "${rsha}:refs/heads/${br}-before-${utc_ts}" \
      || die "push_realticket_branches_to_origin: origin rename-push failed (${br}-before-${utc_ts})"
    git -C "$REALTICKET_DIR" push -f -u origin "$br" \
      || die "push_realticket_branches_to_origin: origin force push failed for $br"
  else
    # origin 에 미존재 → 단순 새 push
    git -C "$REALTICKET_DIR" push -u origin "$br" \
      || die "push_realticket_branches_to_origin: origin push failed for $br"
  fi
}
