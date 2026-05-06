# 00-contracts — 공통 계약 (단일 진실)

본 영역은 7개 영역이 공통으로 의존하는 계약을 lock한다. 다른 영역 문서는 본 파일을 참조하며, 아래 정의를 **재진술하지 않는다**.

5개 단일 진실 항목: (1) manifest schema 16 core fields + optional `bench_stack` (2) region·slot·iteration 모델 (3) run_id 형식 (4) 결과 디렉토리 구조 (5) 용어집.

---

## Manifest Schema (16 core fields + optional `bench_stack`)

매니페스트 1개가 1 벤치마크 세트의 모든 변수를 정의한다. 매니페스트만 보면 무엇이 어떻게 측정되는지 100% 결정된다.

| # | 필드 | 타입 | required | 의미 |
|---|------|------|----------|------|
| 1 | `manifest_id` | string | ✓ | 매니페스트 식별자 (run_id slug 1차 입력) |
| 2 | `run_id_prefix` | string | ✓ | run_id 생성 시 prefix (보통 manifest_id와 동일) |
| 3 | `iterations` | int | ◐ | 반복 회차 N. `duration`과 상호 배타 |
| 4 | `duration` | ISO8601-like (`6h`·`10m`) | ◐ | 총 실행 시간. `iterations`와 상호 배타. N = floor((duration-warmup)/(per_run+cooldown)) |
| 5 | `warmup` | duration | ✓ | 슬롯 ready 대기 시간 (per-run 시작 전) |
| 6 | `per_run` | duration | ✓ | 1 iteration의 부하 시간 |
| 7 | `cooldown` | duration | ✓ | iteration 종료 후 다음 시작까지 |
| 8 | `max_failures` | int | ✓ | 누적 실패 iter ≥ 본 값이면 run 중단 (FAILED 마커) |
| 9 | `plan_path` | string (path to Plan.json) | ✓ | PlanGenerator 출력 JSON 경로. **regions는 Plan.json에만 정의 (Lock #4)** |
| 10 | `prom_url` | string (URL) | ✓ | Prometheus base URL (`http://192.168.138.2:9090`) |
| 11 | `prom_step` | duration | ✓ | Prometheus query_range step (예: `15s`) |
| 12 | `reset_path` | string (URL path) | ✓ | BE reset endpoint path (`/booking/init/:eventId`) |
| 13 | `event_ids` | int[] | ✓ | reset 호출할 eventId 배열 (alternating 시 슬롯별 매칭) |
| 14 | `queries` | object[] (`{name,promql,unit}`) | ✓ | summarize 대상 Prometheus 쿼리 목록 |
| 15 | `slots` | object[] (`{name,targetUrl,image_tag,scenario_mode?}`) | ✓ | 슬롯 정의. `scenario_mode`는 슬롯별 override. 최대 2 슬롯 (Lock #3) |
| 16 | `hypotheses` | object[] | ✗ | 가설 절. 미존재 시 `summarize.py`가 가설 섹션 미생성 |
| + | `bench_stack` | object (`{alpha_test_account, beta_dual_slots, gamma_sentinel, delta_autoscaler}` — 모두 boolean, default `false`) | ✗ | 16 core fields 외 optional object. 4 기능 토글. 미존재 시 모두 disabled — base.yml 단독 deploy |

> **Lock #3** (alternating only): `slots[]` ≤ 2 + 두 슬롯 동시 부하 금지. iteration이 슬롯을 번갈아 선택.
>
> **Lock #4** (region 단일 진실): `plan_path`가 가리키는 Plan.json의 `stats.regions`와 `requests[].region`이 region/slot/iteration 모델의 원천. 매니페스트는 regions를 override하지 않는다.

---

## Region·Slot·Iteration 모델

세 개념이 한 벤치마크의 좌표를 결정한다.

```
slot      = "baseline" | "candidate"            # Lock #3: alternating only, 최대 2
iteration = 매니페스트 내 N번째 반복 회차       # 1..N (iterations 또는 duration 자동 계산)
region    = (name: str, duration_ms: int, actions: [{kind: book_seats|section_move|wait|subscribe|confirm|login, ...}])
            # PlanGenerator의 PlanConfig.json regions:가 단일 진실 (Lock #4)
            # 표준 6 키워드: wait·subscribe·book_seats·section_move·confirm·login
```

식별자 패턴:

```
<region>-<slot>-<iter>     # 예: booking-baseline-1, booking-candidate-2
```

> region은 한 iteration 내부의 시간 구간 분할이다 (warmup·browse·booking·post 등). iteration·slot과 차원이 다르다 — 한 iter 안에 region이 N개 직렬 누적된다.

---

## run_id 형식

```
<manifest_id>-<UTC-timestamp>     # 예: dry-run-001-20260502-000552
```

- `<manifest_id>` = 매니페스트 frontmatter의 `manifest_id` 또는 `run_id_prefix`
- `<UTC-timestamp>` = `YYYYMMDD-HHMMSS` (UTC, run.sh 시작 시점)

결과 디렉토리: `bench/results/<run_id>/` 1단계 트리.

---

## 결과 디렉토리 구조

```
bench/results/<manifest_id>-<UTC-timestamp>/        # ex: bench/results/dry-run-001-20260502-000552/
├── RUNNING | COMPLETED | FAILED                # 마커 1개. 종료 상태 단일 진실
├── progress.json                                # 6 필드: current_iter·total_iter·phase·started_at·updated_at·eta
├── iter-1-baseline/                             # iteration 1 / slot baseline
│   ├── simulation.log                           # Gatling 출력
│   ├── stats.json                               # parse_simulation_log.py 출력 (집계)
│   ├── raw_requests.jsonl                       # per-request 1줄 JSON, region 라벨 부착
│   └── prometheus_<query>.csv                   # prom_query.py 출력 (region 슬라이스)
├── iter-2-candidate/                            # alternating: 다음 iter는 다른 slot
│   └── ... (동일 구조)
└── SUMMARY.md                                   # summarize.py 출력 (regions × queries cross product + 가설 판정)
```

> **마커 단일 진실:** RUNNING은 시작 시 1번 작성, COMPLETED 또는 FAILED 둘 중 하나가 종료 시 대체. 두 마커 동시 존재 = bug.
>
> **progress.json 6 필드:** `current_iter`·`total_iter`·`phase`(warmup|run|cooldown|done)·`started_at`·`updated_at`·`eta`. fire-and-forget 모드에서 사용자가 진행 상태 확인 가능.
>
> **iter 디렉토리 명명:** `iter-<N>-<slot>` 패턴.

---

## 매니페스트 ID 브랜치 derive 규칙

매니페스트 1개는 외부 repo(gatling·RealTicket)에 매니페스트 ID 포함 브랜치를 만들어 일회성 코드 변경을 격리한다. 브랜치 명명은 `manifest_id`(schema 1번 필드) + `slots[].name`(schema 15번 필드)에서 derive된다.

```
gatling repo  : bench/<manifest_id>                    # 슬롯 무관 단일 브랜치
RealTicket    :
   메타 브랜치 : bench/<manifest_id>                    # 항상 존재. 슬롯 무관 공통 코드 + bench-stack/<manifest_id>.yml
   슬롯 브랜치 : bench/<manifest_id>/<slot_name>        # 슬롯 ≥ 2일 때만 추가
```

| 항목 | 값 |
|------|----|
| Gatling 브랜치 | `bench/<manifest_id>` (슬롯 수 무관, 항상 1개) |
| RealTicket 메타 브랜치 | `bench/<manifest_id>` (변경 없는 매니페스트도 반드시 생성) |
| RealTicket 슬롯 브랜치 | `bench/<manifest_id>/<slot_name>` (슬롯 N개 시 N개) |
| 종료 상태 | 두 repo 모두 main 체크아웃 복귀 + 브랜치 영구 보존 (삭제 X) |
| bench-stack yml 명명 | `bench-stack/<manifest_id>.yml` (1 매니페스트 = 1 yml) |
| 기본 Dockerfile | `back/Dockerfile.dev-in-local` (RealTicket repo, VM이 빌드) |

---

## 용어집

| 용어 | 의미 | 헷갈리기 쉬운 것 |
|------|------|-----------------|
| **영역 (area)** | 본 플랫폼의 7개 책임 범위 | v1.0 workstream의 후계 |
| **slot** | 매니페스트의 한 슬롯 — `baseline` 또는 `candidate` | iteration과 다름 |
| **iteration** | 매니페스트 1세트 내 반복 회차 (한 슬롯에 대한 한 번의 시뮬레이션) | slot과 다름 |
| **region** | 한 시뮬레이션(iter) 내 시간 구간. PlanConfig.json `regions:`가 단일 진실 (Lock #4) | iteration과 다름 — region은 한 iter 내부 분할 |
| **manifest** | 1 벤치마크 세트의 모든 변수를 정의한 단일 YAML | Plan(JSON)과 다름 |
| **Plan (대문자)** | PlanGenerator.py 출력 시나리오 정의 JSON | 매니페스트와 다름 |
| **fire-and-forget** | run.sh가 VM `nohup`으로 실행되어 ssh·conversation 종료 후에도 지속 (Lock #5) | foreground 실행과 반대 |
| **alternating** | 두 슬롯을 번갈아 측정 (한 번에 한 슬롯). Lock #3 | concurrent와 반대 |
| **regions × queries cross product** | summarize.py가 SUMMARY.md에 자동 생성하는 표 — region별 × Prometheus query별 평균/피크 | 단순 슬롯 비교 표와 다름 |
| **가설 절 (hypotheses)** | 매니페스트 16번째 필드. summarize.py가 cross product 결과로 PASS/FAIL 판정 | 미존재 시 가설 섹션 미생성 |

---

## AI 작업 지침

### 읽는 시점

- **매니페스트 작성 시작 시** — 16 core fields + optional `bench_stack` 표를 참조하여 수집해야 할 입력을 파악
- **브랜치 명명 시** — derive 규칙 표의 패턴(`bench/<manifest_id>`)을 단일 진실로 사용
- **결과 디렉토리 생성 시** — 결과 디렉토리 구조 트리를 그대로 따름 (재정의 X)
- **region 식별자 필요 시** — `<region>-<slot>-<iter>` 패턴이 단일 진실
- **용어 정의 필요 시** — 용어집을 먼저 확인. 동의어·혼용 표현 사용 금지

### 수정하는 시점

- **schema 필드 추가** — 16 core fields 또는 optional object 추가 여부를 명확히 구분하고 하위 호환성 명시 필수
- **브랜치 derive 규칙 변경** — derive 규칙 표 수정 후 04/05 문서의 해석 섹션도 cross-check

### 행동 금지

- 이 파일의 정의를 다른 영역 문서에 복사·재진술 금지 — 항상 이 파일로 link
- region을 재명명하거나 새 모델 추가 금지
