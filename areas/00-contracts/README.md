# 00-contracts — 공통 계약 (단일 진실)

본 영역은 7개 영역이 공통으로 의존하는 계약을 lock한다. 다른 영역 문서는 본 파일을 참조하며, 아래 정의를 **재진술하지 않는다**.

5개 단일 진실 항목: (1) manifest schema 15 core fields + optional `bench_stack`·`context`·`implementation_plan`·`workflow_state` (2) slot·iteration 모델 (3) run_id 형식 (4) 결과 디렉토리 구조 (5) 용어집.

---

## Manifest Schema (15 core fields + optional objects)

매니페스트 1개가 1 벤치마크 세트의 모든 변수를 정의한다. 매니페스트만 보면 무엇이 어떻게 측정되는지 100% 결정된다.

| # | 필드 | 타입 | required | 의미 |
|---|------|------|----------|------|
| 1 | `manifest_id` | string | ✓ | 매니페스트 식별자 (run_id slug 1차 입력) |
| 2 | `run_id_prefix` | string | ✓ | run_id 생성 시 prefix (보통 manifest_id와 동일) |
| 3 | `iterations` | int | ◐ | 반복 회차 N. `duration`과 상호 배타 |
| 4 | `duration` | ISO8601-like (`6h`·`10m`) | ◐ | 총 실행 시간. `iterations`와 상호 배타. N = floor((duration-warmup)/(`derived_per_run_s`+cooldown)) — `derived_per_run_s` 도출 규칙은 아래 § per_run 도출 |
| 5 | `warmup` | duration | ✓ | 슬롯 ready 대기 시간 (per-run 시작 전) |
| 6 | `cooldown` | duration | ✓ | iteration 종료 후 다음 시작까지 |
| 7 | `max_failures` | int | ✓ | 누적 실패 iter ≥ 본 값이면 run 중단 (FAILED 마커) |
| 8 | `plan_path` | string (path to Plan.json) | ✓ | PlanGenerator 출력 JSON 경로. 좌석 배정 시뮬레이션 결과 (requests·collision_groups·stats). |
| 9 | `prom_url` | string (URL) | ✓ | Prometheus base URL (`http://192.168.138.2:9090`) |
| 10 | `prom_step` | duration | ✓ | Prometheus query_range step (예: `1s`) |
| 11 | `reset_path` | string (URL path) | ✓ | BE reset endpoint path (`/booking/init/:eventId`) |
| 12 | `event_ids` | int[] | ✓ | reset 호출할 eventId 배열 (alternating 시 슬롯별 매칭) |
| 13 | `queries` | object[] (`{name,promql,unit}`) | ✓ | summarize 대상 Prometheus 쿼리 목록 |
| 14 | `slots` | object[] | ✓ | 슬롯 정의. 최대 2 슬롯 (Lock #3). sub-fields: `name`(✓) `targetUrl`(✓) `image_tag`(✓) `scenario_mode`(◐ 슬롯별 override, 사용자 확인 시에만 기록) `source_branch`(◐ RealTicket 슬롯 브랜치 기점. 미지정 시 `origin/dev`. 02-orchestration 이 소비) |
| 15 | `hypotheses` | object[] | ✗ | 가설 절. 미존재 시 `summarize.py`가 가설 섹션 미생성 |
| + | `bench_stack` | object (`{alpha_test_account, beta_dual_slots, gamma_sentinel, delta_autoscaler}` — 모두 boolean, default `false`) | ✗ | optional. 4 기능 토글. 미존재 시 모두 disabled — base.yml 단독 deploy |
| + | `context` | object | ✗ | optional. 실험 목적·비교 변수·설계 결정 기록. **파이프라인 미소비** — 새 세션 컨텍스트 복원용. 매니페스트 작성 세션에서 AI가 논의 내용을 채움 |
| + | `implementation_plan` | object | ✗ | optional. 실행 전 외부 repo 구현 계획. `status: pending\|completed` + 영역별 계획. **run.sh preflight 소비** — `status: completed` 가 아니거나 `gatling.research_summary`/`gatling.change_plan` 이 비어 있으면 벤치마크 실행 금지 |
| + | `workflow_state` | object | ✗ | optional. **실행 전 AI 작업 재개 상태**. 현재 작업 포인터·마지막 완료·다음 행동을 기록한다. `run.sh` 는 소비하지 않으며, 벤치마크 시작 후 진행 상태는 결과 디렉토리 마커와 `progress.json` 이 단일 진실 |

> **`scenario_mode` provenance rule:** `slots[].scenario_mode` 는 Gatling 실행 계약값(`-PscenarioMode`)이므로 AI가 임의 derive하지 않는다. 값은 사용자가 명시 입력하거나, AI가 제안한 값을 사용자가 확인한 경우에만 YAML에 기록한다. 사용자가 확정하지 않으면 필드를 생략하고 `implementation_plan.gatling.scenario_decisions` 에 "scenario_mode 이름/구현 확정" pending 결정을 남긴다. 예시 파일의 커스텀 mode 이름이나 기존 기본 mode 이름을 사용자 확인 없이 실제 매니페스트 값으로 전용 금지.

### `implementation_plan.gatling` 리서치 구조

매니페스트 작성 세션은 Gatling repo 를 read-only 로 리서치하고, 결과를 매니페스트에 직접 기록한다. 실제 브랜치 분기·코드 수정·Plan.json 생성·commit·push 는 구현 세션 책임이다.

```yaml
implementation_plan:
  status: "pending"        # pending | completed
  gatling:
    branch: "bench/<manifest_id>"
    base: "origin/main"
    research_summary: "<기본 4종 mode 충족 가능 여부 + 커스텀 필요성 판단>"
    repo_state:
      current_branch: "<read-only 확인값>"
      dirty: false
      origin_main_latest: "<short hash date subject>"
      protected_existing_changes: []
    scenario_decisions:
      - slot: "baseline"
        mode: "PARALLEL"
        custom_required: false
        rationale: "<왜 이 mode 인지>"
    change_plan:
      - id: "G1"
        file: "app/src/gatling/java/..."
        intent: "<변경 목적>"
        base_code_path: "<복사/확장 기준 코드>"
        preserve: ["login flow", "Plan parsing", "user injection"]
        done: false
    acceptance_checks:
      - "PlanGenerator.py --selftest"
      - "EFFECTIVE_CONFIG 에 scenarioMode/planPath/targetUrl 반영 확인"
      - "Plan.json stats.simulation_duration_ms > 0 확인"
      - "BookingSimulation scenario dispatch 확인"
    risks:
      - "화이트리스트 밖 -P 키는 silent no-op"
      - "alpha_test_account=true 일 때 login 액션 생략 필요"
```

`run.sh` 의 실행 전 preflight 는 최소한 `implementation_plan.status == completed`, `implementation_plan.gatling.research_summary` 존재, `implementation_plan.gatling.change_plan` 1개 이상을 검사한다.

### `workflow_state` 재개 구조

`workflow_state` 는 매니페스트 작성 이후부터 `run.sh` 시작 전까지 AI가 직접 갱신하는 hand-off 블록이다. 새 세션은 이 절을 먼저 읽고, `current_task_ref` 가 가리키는 `implementation_plan` 작업부터 이어서 진행한다.

```yaml
workflow_state:
  status: "implementing"  # drafting | implementing | blocked | ready_to_run
  active_area: "04-gatling-integration"
  current_task_ref: "implementation_plan.gatling.change_plan[G2]"
  last_completed: "G1 Config.java 변경 완료"
  next_action: "G2 app/build.gradle -P 포워딩 구현 후 acceptance_checks 1차 실행"
  updated_at: "2026-05-07T00:00:00Z"
  handoff_notes:
    - "외부 repo 변경은 매니페스트 ID 브랜치에만 적용"
```

운영 규칙:

- 작업을 하나 완료할 때마다 해당 `implementation_plan.*.done` 을 갱신하고 `workflow_state` 를 같은 커밋/세션에서 갱신한다.
- 세션을 종료하거나 막혔을 때는 `next_action` 을 자연어 1문장으로 남긴다. 새 세션이 별도 대화 기록 없이 바로 실행할 수 있어야 한다.
- 모든 실행 전 작업이 끝나면 `implementation_plan.status: completed`, `workflow_state.status: ready_to_run`, `next_action: "BENCH_PREFLIGHT_ONLY=1 ..."` 형태로 둔다.
- `run.sh` 실행 이후의 iteration 진행률·Prometheus 수집·SUMMARY 생성 상태는 매니페스트에 쓰지 않는다. 이 구간의 단일 진실은 `bench/results/<manifest_id>/<run_id>/` 의 마커와 산출물이다.

> **per_run 도출 규칙 (rev 2):** 매니페스트는 `per_run` 을 입력받지 않는다. PlanGenerator 가 `simulation_duration_ms` 입력 없이 `request_delay_mean`/`num_users`/`seats_per_user` 로 자연 종료 — Plan.json 의 `stats.simulation_duration_ms` 가 결정. 02-orchestration 이 `per_run_ms = ceil(simulation_duration_ms × 1.1)` 도출하여 iter_meta.json 에 기록 + phases.json 의 `main_booking` end_ms 로 사용. 본예매(main_booking) region 의 길이 = derived per_run.

> **Lock #3** (alternating only): `slots[]` ≤ 2 + 두 슬롯 동시 부하 금지. iteration이 슬롯을 번갈아 선택.

---

## Slot·Iteration 모델

두 개념이 한 벤치마크의 좌표를 결정한다.

```
slot      = "baseline" | "candidate"            # Lock #3: alternating only, 최대 2
iteration = 매니페스트 내 N번째 반복 회차       # 1..N (iterations 또는 duration 자동 계산)
```

식별자 패턴:

```
<slot>-<iter>     # 예: baseline-1, candidate-2
```

---

## run_id 형식

```
<run_id_prefix>-<UTC-timestamp>   # 예: dry-run-001-20260502-000552
```

- `<run_id_prefix>` = 매니페스트 frontmatter의 `run_id_prefix` (미지정 시 `manifest_id`)
- `<UTC-timestamp>` = `YYYYMMDD-HHMMSS` (UTC, run.sh 시작 시점)
- `<manifest_id>` = `bench/results/` 바로 아래의 안정적인 상위 폴더명

결과 디렉토리: `bench/results/<manifest_id>/<run_id>/` 트리. `bench/results/` 바로 아래는 매니페스트 단위로만 나뉜다.

---

## 결과 디렉토리 구조

```
bench/results/<manifest_id>/<run_id>/               # ex: bench/results/dry-run-001/dry-run-001-20260502-000552/
├── RUNNING | COMPLETED | FAILED                # 마커 1개. 종료 상태 단일 진실
├── progress.json                                # 6 필드: current_iter·total_iter·phase·started_at·updated_at·eta
├── phases.json                                  # 시뮬레이션 단계(region) 정의 — run 단위 1개. 부재 시 prom_query 는 _iter_total 만 슬라이싱
├── iter-1-baseline/                             # iteration 1 / slot baseline
│   ├── simulation.log                           # Gatling 출력
│   ├── gatling-report/                          # Gatling HTML 결과 보고서 (app/build/reports/gatling 최신 디렉토리 복사본)
│   ├── gatling-report-source.txt                # 원본 Gatling report 디렉토리 경로
│   ├── iter_meta.json                           # iter_start_epoch · slot · iter 등
│   ├── stats.json                               # parse_simulation_log.py 출력 (request_name 별 집계)
│   ├── raw_requests.jsonl                       # per-request 1줄 JSON (request_name·status·response_time_ms·timestamp_epoch·source)
│   └── prom_metrics.json                        # prom_query.py 출력 (query × phase 슬라이스 — _iter_total + phase별)
├── iter-2-candidate/                            # alternating: 다음 iter는 다른 slot
│   └── ... (동일 구조)
└── SUMMARY.md                                   # summarize.py 출력 (slot × request_type 레이턴시 + slot × phase × Prometheus + 가설 판정)
```

> **마커 단일 진실:** RUNNING은 시작 시 1번 작성, COMPLETED 또는 FAILED 둘 중 하나가 종료 시 대체. 두 마커 동시 존재 = bug.
>
> **progress.json 6 필드:** `current_iter`·`total_iter`·`phase`(warmup|run|cooldown|done)·`started_at`·`updated_at`·`eta`. fire-and-forget 모드에서 사용자가 진행 상태 확인 가능.
>
> **iter 디렉토리 명명:** `iter-<N>-<slot>` 패턴.

---

## iter_meta.json 스키마

iter 단위 메타. 02-orchestration 의 `write_iter_meta` 가 작성, 03-analysis 의 `prom_query.py` 가 소비.

| 필드 | 타입 | required | 의미 |
|------|------|----------|------|
| `iter` | int | ✓ | iter 번호 (1-based) |
| `slot` | string | ✓ | iter 가 사용한 슬롯 이름 (`baseline` \| `candidate`) |
| `plan_path` | string | ✓ | Plan.json 경로 (매니페스트의 `plan_path` 와 동일) |
| `iter_start_epoch` | int | ✓ | iter 시작 시각 (epoch 초) — Gatling 시작 직전 |
| `iter_end_epoch` | int | ◐ | iter 종료 시각 (epoch 초) — Gatling 종료 직후 측정. 정상 종료 시 필수 |
| `per_run_ms` | int | ◐ | 본예매 region 의 길이 ms = `ceil(Plan.json.stats.simulation_duration_ms × 1.1)`. orchestration 이 도출 |
| `reset_failed` / `reset_failed_event` / `reset_failed_http` | bool/string | ✗ | reset 재시도 모두 실패한 케이스 (정상 iter 에는 부재) |

**prom_query iter 윈도우 결정 우선순위:** `iter_end_epoch` 실측 → `iter_start + per_run_ms/1000` 도출 → 둘 다 부재 시 error.

---

## phases.json 스키마

매니페스트 시나리오의 **시뮬레이션 단계(region)** 정의. run_dir 1개당 1 파일 — 모든 iter 가 공유한다.
phases.json 부재 시 `prom_query.py` 는 `_iter_total` 윈도우만 집계 (단계 슬라이싱 미적용 — 하위 호환).

```json
{
  "phases": [
    {"name": "auth_check",   "start_ms": 0,     "end_ms": 1500},
    {"name": "subscribe",    "start_ms": 51500, "end_ms": 53000},
    {"name": "main_booking", "start_ms": 53000, "end_ms": 180000}
  ]
}
```

| 필드 | 타입 | required | 의미 |
|------|------|----------|------|
| `phases[]` | object[] | ✓ | 단계 배열 (시간순) |
| `phases[].name` | string `^[a-z][a-z0-9_]*$` | ✓ | 단계 식별자. `_iter_total` 예약어 (전체 iter 윈도우 자동 생성) — 사용 금지 |
| `phases[].start_ms` | int ≥ 0 | ✓ | iter_start_epoch 기준 ms |
| `phases[].end_ms` | int > start_ms | ✓ | iter_start_epoch 기준 ms |

**윈도우 의미:** 단계 = `[iter_start + start_ms, iter_start + end_ms)` (시작 inclusive, 끝 exclusive).
**gap 허용:** 인접 단계 사이의 빈 구간은 분석 대상 외 (대기 시간 등 — 측정해도 의미 없음).
**작성 책임:** 02-orchestration (run 시작 시 매니페스트 + Gatling Config 스냅샷에서 derive).
**소비:** 03-analysis `prom_query.py` (phase별 Prometheus 슬라이싱) + `summarize.py` (slot × phase × query 표 생성).
**매핑 출처:** 자연어 → Config → phases.json 변환 규칙은 [04-gatling § region ↔ Gatling Config 대기 설정 매핑](../04-gatling-integration/README.md) 참조.

---

## 매니페스트 ID 브랜치 derive 규칙

매니페스트 1개는 외부 repo(gatling·RealTicket)에 매니페스트 ID 포함 브랜치를 만들어 일회성 코드 변경을 격리한다. 브랜치 명명은 `manifest_id`(schema 1번 필드) + `slots[].name`(schema 15번 필드)에서 derive된다.

```
gatling repo  : bench/<manifest_id>                    # 슬롯 무관 단일 브랜치
RealTicket    :
   메타 브랜치 : bench/<manifest_id>/meta               # 항상 존재. 슬롯 무관 공통 코드 + bench-stack/<manifest_id>.yml
   슬롯 브랜치 : bench/<manifest_id>/<slot_name>        # 슬롯 ≥ 2일 때만 추가
```

| 항목 | 값 |
|------|----|
| Gatling 브랜치 | `bench/<manifest_id>` (슬롯 수 무관, 항상 1개) |
| RealTicket 메타 브랜치 | `bench/<manifest_id>/meta` (변경 없는 매니페스트도 반드시 생성) |
| RealTicket 슬롯 브랜치 | `bench/<manifest_id>/<slot_name>` (슬롯 N개 시 N개) |
| 종료 상태 | 두 repo 모두 main 체크아웃 복귀 + 브랜치 영구 보존 (삭제 X) |
| bench-stack yml 명명 | `bench-stack/<manifest_id>.yml` (1 매니페스트 = 1 yml) |
| 기본 Dockerfile | `back/Dockerfile.dev-in-local` (RealTicket repo, VM이 빌드) |

> **RealTicket Git ref 제약:** `bench/<manifest_id>` 루트 브랜치와 `bench/<manifest_id>/<slot_name>` 슬롯 브랜치는 Git 내부에서 각각 파일 ref와 디렉토리 ref로 충돌하므로 동시에 존재할 수 없다. RealTicket 메타 브랜치의 단일 진실은 `bench/<manifest_id>/meta`이며, 루트 `bench/<manifest_id>` ref는 사용하지 않는다.

---

## 용어집

| 용어 | 의미 | 헷갈리기 쉬운 것 |
|------|------|-----------------|
| **영역 (area)** | 본 플랫폼의 7개 책임 범위 | v1.0 workstream의 후계 |
| **slot** | 매니페스트의 한 슬롯 — `baseline` 또는 `candidate` | iteration과 다름 |
| **iteration** | 매니페스트 1세트 내 반복 회차 (한 슬롯에 대한 한 번의 시뮬레이션) | slot과 다름 |
| **region** | 매니페스트 시나리오의 시뮬레이션 단계 (예: 입장 권한 확인 / 구독 / 본예매). 단계 흐름과 단계 간 딜레이는 Gatling 시뮬레이션 코드 + `Config.java`가 단일 진실 — 매니페스트 yaml에 직접 명시 X. [04-gatling § region ↔ Config 매핑](../04-gatling-integration/README.md) 참조 | iteration과 다름 — region은 한 iter 내부 단계 분할 |
| **manifest** | 1 벤치마크 세트의 모든 변수를 정의한 단일 YAML | Plan(JSON)과 다름 |
| **Plan (대문자)** | PlanGenerator.py 출력 시나리오 정의 JSON (simulation_duration_ms · requests · collision_groups) | 매니페스트와 다름 |
| **fire-and-forget** | run.sh가 VM `nohup`으로 실행되어 ssh·conversation 종료 후에도 지속 (Lock #4) | foreground 실행과 반대 |
| **alternating** | 두 슬롯을 번갈아 측정 (한 번에 한 슬롯). Lock #3 | concurrent와 반대 |
| **가설 절 (hypotheses)** | 매니페스트 15번째 필드. summarize.py가 slot × request_type 표를 생성 후 PASS/FAIL 판정 | 미존재 시 가설 섹션 미생성 |
| **implementation_plan** | 매니페스트 optional 절. 외부 repo 구현 계획 + 완료 상태. Gatling 리서치 요약과 파일별 변경 계획을 포함하며 `status: pending` 이면 벤치마크 실행 금지 | context 절과 다름 — context는 설계 기록, implementation_plan은 실행 전 task 목록 |
| **workflow_state** | 매니페스트 optional 절. 실행 전 AI 작업의 현재 위치와 다음 행동을 기록하는 재개 포인터 | 결과 디렉토리 `progress.json` 과 다름 — workflow_state 는 벤치마크 시작 전 hand-off 용 |

---

## AI 작업 지침

### 읽는 시점

- **매니페스트 작성 시작 시** — 15 core fields + optional objects 표를 참조하여 수집해야 할 입력을 파악
- **브랜치 명명 시** — derive 규칙 표의 패턴(Gatling `bench/<manifest_id>`, RealTicket `bench/<manifest_id>/meta` 및 `bench/<manifest_id>/<slot_name>`)을 단일 진실로 사용
- **결과 디렉토리 생성 시** — 결과 디렉토리 구조 트리를 그대로 따름 (재정의 X)
- **용어 정의 필요 시** — 용어집을 먼저 확인. 동의어·혼용 표현 사용 금지

### 수정하는 시점

- **schema 필드 추가** — 15 core fields 또는 optional object 추가 여부를 명확히 구분하고 하위 호환성 명시 필수
- **브랜치 derive 규칙 변경** — derive 규칙 표 수정 후 04/05 문서의 해석 섹션도 cross-check

### 행동 금지

- 이 파일의 정의를 다른 영역 문서에 복사·재진술 금지 — 항상 이 파일로 link
