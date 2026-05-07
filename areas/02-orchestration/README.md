# 02-orchestration — run.sh · 브랜치 라이프사이클 · fire-and-forget

본 영역은 매니페스트 1개를 입력으로 단대단 자동화하는 벤치마크 실행 흐름을 책임진다. **VM 고정 인프라(Swarm·Sentinel·Prom/Grafana·SSH/키)는 [06-vm-environment/README.md](../06-vm-environment/README.md)** — 두 영역의 경계는 "벤치마크 시점에 바뀌는가"다.

manifest schema 정의는 [00-contracts/README.md](../00-contracts/README.md) 참조.

---

## run.sh 17 함수

| # | 함수 | 분류 | 책임 (1줄) |
|---|------|------|----------|
| 1 | `parse_duration()` | util | `6h`·`10m`·`30s` ISO8601-like 문자열을 초 단위 정수로 변환 |
| 2 | `manifest_yq()` | util | yq로 매니페스트 1 필드 조회. multi-document YAML 첫 문서만 파싱 |
| 3 | `prepare_gatling_branch()` | branch | gatling repo `bench/<manifest_id>` 브랜치 분기 + 코드 수정 + commit |
| 4 | `prepare_realticket_branches()` | branch | RealTicket repo 메타·슬롯 브랜치 분기 + yml commit + push |
| 5 | `generate_bench_stack_yml()` | branch | `areas/02-orchestration/templates/docker-stack.base.yml` → α/β/γ/δ 변형 → `bench-stack/<manifest_id>.yml` 생성 |
| 6 | `apply_untracked_overrides()` | branch | VM에 git 미추적 빌드 파일 scp 적용 + 경로 목록 기록 |
| 7 | `build_vm_images()` | branch | VM: 매니페스트 ID 브랜치 pull → Dockerfile.dev-in-local 빌드 → docker stack deploy |
| 8 | `admin_login()` | lifecycle | RealTicket `POST /user/login`으로 ADMIN SID 쿠키 획득 + HTTP 200 검증 |
| 9 | `reset_slots()` | lifecycle | 활성 슬롯의 `event_ids[]`에 `POST /booking/init/:eventId` ADMIN 호출 |
| 10 | `get_slot_for_iter()` | lifecycle | iteration 회차(1..N)로 슬롯 선택. `idx = (iter-1) % len(slots)` — Lock #3 alternating |
| 11 | `run_gatling()` | gatling | `./gradlew gatlingRunAndArchive -P...` 호출. -P 키는 [04-gatling-integration/README.md](../04-gatling-integration/README.md) 참조 |
| 12 | `collect_prometheus()` | prom | Prometheus `query_range` API로 `queries[]` PromQL 수집 → `prometheus_<query>.csv` |
| 13 | `write_progress()` | lifecycle | `progress.json.tmp` → `mv` (atomic). 6 필드 갱신 |
| 14 | `write_iter_meta()` | lifecycle | iter 디렉토리에 메타(slot·image_tag·started_at·completed_at·exit_code) JSON 작성 |
| 15 | `rollback_untracked_overrides()` | branch | `untracked-overrides.list`의 경로만 VM에서 롤백. 다른 환경 변경 금지 |
| 16 | `restore_main_branches()` | branch | gatling + RealTicket repo 모두 main 체크아웃 복귀. 브랜치 삭제 X |
| 17 | `cleanup_on_exit()` + `main()` | lifecycle | `trap EXIT`. RUNNING → FAILED 원자 전이 + rollback + restore 호출. `main()` = 전체 오케스트레이션 |

---

## 매니페스트 실행 3단계

### 준비 단계 (매니페스트 시작)

```
prepare_gatling_branch()      # 3번 함수
prepare_realticket_branches() # 4번 함수
generate_bench_stack_yml()    # 5번 함수
apply_untracked_overrides()   # 6번 함수
build_vm_images()             # 7번 함수
admin_login()                 # 8번 함수
```

### iter 루프 (매니페스트 실행)

```
for iter in 1..N:
    get_slot_for_iter(iter)   # 10번 함수 — alternating
    reset_slots()             # 9번 함수
    run_gatling()             # 11번 함수
    collect_prometheus()      # 12번 함수
    write_progress()          # 13번 함수
    write_iter_meta()         # 14번 함수
```

### 복귀 단계 (매니페스트 종료)

```
restore_main_branches()       # 16번 함수 (cleanup_on_exit trap 포함)
rollback_untracked_overrides() # 15번 함수
```

---

## Fire-and-forget + 마커

Lock #4의 구현. 사용자 한 줄로 시작:

```bash
nohup bash areas/02-orchestration/run.sh bench/manifests/<manifest>.yaml >/dev/null 2>&1 & disown
```

이후 ssh 세션·AI conversation을 종료해도 run.sh는 VM에서 지속. 로그는 run.sh가 생성한 `bench/results/<manifest_id>/<run_id>/run.log`에 기록된다. 마커 + `progress.json`이 유일한 진행/종료 인터페이스.

| 상태 | 마커 | 의미 |
|------|------|------|
| 실행 중 | `RUNNING` | run.sh 시작 시 1번 작성 |
| 정상 종료 | `COMPLETED` | 모든 iter 완료 시 RUNNING 대체 |
| 실패 종료 | `FAILED` | max_failures 도달 또는 치명 에러 시 RUNNING 대체 |

두 마커 동시 존재 = bug. `trap EXIT`이 모든 종료 경로를 커버.

---

## Slot Alternating

Lock #3의 구현. 매 iter는 정확히 1개 슬롯에 부하를 건다.

```
iter 1 → slots[0] (baseline)
iter 2 → slots[1] (candidate)
iter 3 → slots[0] (baseline)
iter N → slots[(N-1) % 2]
```

concurrent dual 부하는 영구 미지원 — 구현 추가도 lock 위배.

---

## 이미지 swap·stack restart 절차

벤치마크 시점에 바뀌는 이미지와 stack 재시작은 본 영역 책임이다. VM의 Swarm·Prometheus·SSH 같은 고정 인프라는 06 영역에 남긴다.

0. `generate_bench_stack_yml()`이 매니페스트의 4 기능 토글을 읽어 RealTicket repo의 `bench-stack/<manifest_id>.yml`을 생성한다.
1. `prepare_realticket_branches()`가 메타·슬롯 브랜치에 동일 yml을 commit·push한다.
2. `apply_untracked_overrides()`가 필요한 VM 미추적 빌드 파일만 명시 목록으로 배치한다.
3. `build_vm_images()`가 VM에서 매니페스트 ID 브랜치를 pull하고 슬롯별 `nest:<manifest_id>` 이미지를 빌드한다.
4. `build_vm_images()`가 `docker stack deploy -c bench-stack/<manifest_id>.yml realticket`로 stack을 갱신한다.

실패 또는 종료 시 `rollback_untracked_overrides()`와 `restore_main_branches()`가 cleanup 경로에서 호출된다. 외부 repo 브랜치는 삭제하지 않는다.

---

## phases.json 작성 (region 단계 단일 진실)

매니페스트의 region 구성과 단계 간 대기가 결정되면 본 영역이 run 시작 시점에 `<run_dir>/phases.json` 을 derive 작성한다. 03-analysis `prom_query.py` 가 이 파일을 읽어 phase 별 Prometheus 슬라이싱을 수행한다.

| 입력 | 출처 |
|------|------|
| 단계명 + 순서 | 매니페스트 수집 (4)단계 — [01-planning § 매니페스트 수집 흐름](../01-planning/README.md) |
| 단계 간 대기 ms | Gatling Config.java 스냅샷 (`ENABLE_WAITING_*` + `WAITING_*_MILLIS`) — [04-gatling § region ↔ Config 매핑](../04-gatling-integration/README.md) |
| 단계별 활동 시간 추정 | auth/subscribe = AI 추정 (1~5s). **본예매 = `ceil(Plan.json.stats.simulation_duration_ms × 1.1)`** — derived per_run. |

> **per_run 도출:** PlanGenerator 가 자연 종료로 결정한 `simulation_duration_ms` 에 1.1 안전 계수 적용. 매니페스트의 `per_run` 필드는 폐기됨. 도출된 값은 (a) iter_meta.json `per_run_ms` (b) phases.json `main_booking.end_ms` 두 곳에 기록 — 03-analysis 가 둘 다 소비.

| 출력 | 위치 |
|------|------|
| `phases.json` | `bench/results/<manifest_id>/<run_id>/phases.json` (run_dir 1개 — 모든 iter 공유) |

**스키마 단일 진실:** [00-contracts § phases.json 스키마](../00-contracts/README.md).
**부재 시 동작:** prom_query 는 `_iter_total` 만 슬라이싱 (하위 호환).

---

## 수정 가능 파일

| 파일 | 담당 함수 |
|------|---------|
| `areas/02-orchestration/lib/branch.sh` | `prepare_gatling_branch()`, `prepare_realticket_branches()` |
| `areas/02-orchestration/lib/bench_stack.sh` | `generate_bench_stack_yml()` |
| `areas/04-gatling-integration/lib/gatling.sh` | `run_gatling()`, `build_vm_images()` |
| `areas/02-orchestration/lib/lifecycle.sh` | `admin_login()`, `reset_slots()`, iter 루프 |
| `areas/02-orchestration/run.sh` | `main()` 오케스트레이션 |

---

## 불변 조건

- `areas/02-orchestration/lib/branch.sh`와 `areas/02-orchestration/lib/lifecycle.sh`에 commit 명령 0건 — commit은 bench_stack.sh 책임
- `|| true` silent-mask 금지 — 실패는 `die` fail-fast
- 외부 repo main/dev 직접 변경 금지 — 매니페스트 ID 브랜치에만 commit (Lock #2)
- SSHFS·매크로·Postman 호출 추가 금지 (Lock #1)

---

## AI 작업 지침

### AI가 개입하는 시점

**준비 단계:** prepare_gatling_branch → prepare_realticket_branches → generate_bench_stack_yml → build_vm_images 순서로 수행

**iter 루프:** alternating으로 슬롯 선택 → run_gatling → collect_prometheus → write_progress 순서 반복

**복귀 단계:** restore_main_branches (정상·실패·SIGINT 모두)

### 행동 금지

- concurrent dual 부하 구현 추가 금지 (Lock #3 영구 미지원)
- 마커 파일 외의 상태 파일 신규 추가 금지 (Lock #4)
- fire-and-forget 흐름을 foreground로 변경 금지
