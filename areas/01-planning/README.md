# 01-planning — 매니페스트 수집 흐름

본 영역은 AI가 사용자로부터 매니페스트를 지능적으로 수집하는 방법과 순서를 정의한다. schema 정의는 [00-contracts/README.md](../00-contracts/README.md)에 단일 진실로 lock되어 있으며, 본 파일은 그것을 link로만 참조한다.

---

## 매니페스트 수집 흐름 10단계

사용자가 "매니페스트 시작하자" 또는 동등한 자연어 명령을 내리면 AI는 다음 순서로 진행한다.

| 단계 | 질문/입력 대상 | AI 행동 | schema 매핑 |
|------|---------|---------|------------|
| (1a) | **manifest_id (필수 입력)** | 사용자에게 매니페스트 식별자 (영문 kebab-case, 예: `sse-reconnect-vs-patch`)를 **별도 질문으로** 받는다. AI 추측 derive 금지 — 명시 입력 강제. image_tag·브랜치명 등이 이 값에서 derive 되므로 가장 먼저 확정 | `manifest_id` |
| (1b) | **비교 변수 1개 (필수 입력)** | 이번 매니페스트가 측정할 단일 비교 차원 확인 (예: SSE 아키텍처 비교 · Sentinel 적용 유무 · 캐싱 적용 전후). (1a) 와 별도 질문으로 받음 — 한 답변으로 합치지 말 것 | (직접 매핑 X — 후속 단계의 컨텍스트) |
| (2) | **baseline·candidate 슬롯 정의** | `slots[].name` + `targetUrl` + `image_tag`. 슬롯 ≤ 2 (Lock #3). **슬롯 2개면 β=true 강제 + targetUrl baseline=8080·candidate=8081 자동 분리** (§ AI 자동 derive 참조 — 두 슬롯 동일 포트 금지). `scenario_mode` 는 기본 4종/커스텀 여부와 무관하게 사용자 확인 없이 기록 금지 — 아래 § scenario_mode 확정 게이트 참조 | `slots[]` |
| (3) | **docker-stack 4 기능 토글** | α(테스트 계정 사전 로그인 yes/no) · **β(nest 슬롯 개수 — (2) 슬롯 정의에서 양방향 자동 derive: 슬롯 2개면 β=true 강제, 1개면 β=false 강제 — 사용자에게 따로 묻지 않음)** · γ(Sentinel·autoscaling) · δ(autoscaler). 사용자가 명시 안 한 차원(α/γ/δ)은 disabled. **α=true 활성 시 [04-gatling § bench_stack ↔ Gatling 연동 규칙](../04-gatling-integration/README.md) 강제 — `TEST_ACCOUNT_ALREADY_STORED` 활성화 + 커스텀 시나리오 login 생략을 Gatling 구현 계획에 기록** | `bench_stack` |
| (4) | **region 구성 + 단계 간 대기** | 시나리오 단계 흐름 (예: "권한 확인 → 구독 → 본예매") + 단계 사이 대기 시간을 자연어로 수집 → [04-gatling § region ↔ Gatling Config 대기 설정 매핑](../04-gatling-integration/README.md)으로 변환하여 `Config.java` 변경 계획에 기록 | (Config 측 — schema 직접 매핑 X) |
| (5) | **실행 모드 + 타이밍** | `iterations` (정수) XOR `duration` (`6h`·`10m`) 선택 + `warmup` + `cooldown` 입력. **`per_run` 은 묻지 않음** — Plan.json 자연 종료 후 02-orchestration 이 분석용 `main_booking_ms` 를 도출하고, duration mode 는 Gatling static wait + runner overhead + 실측 rolling average 로 wall-clock 1회 시간을 추정 ([00-contracts § per_run / wall-clock timing 규칙](../00-contracts/README.md)) | `iterations`\|`duration`, `warmup`, `cooldown` |
| (6) | **`event_ids`** | reset 호출할 RealTicket 이벤트 ID 배열 | `event_ids` |
| (7) | **PlanConfig 확정 게이트** | PlanGenerator 실행 전에 필요한 `PlanConfig.json` 값을 확정한다. 이전 답변에서 derive 가능한 값은 제안·근거를 밝히고, 부하 강도·좌석 수·section 이동 등 derive 불가능한 값은 반드시 사용자에게 묻는다. 확정 결과는 `context.plan_config` 에 기록하고, 구현 세션 작업으로 `implementation_plan.gatling.change_plan` 에 `PlanConfig.json` 생성/수정 + PlanGenerator 실행을 포함한다. 상세 기준은 아래 § PlanConfig 확정 게이트와 [04-gatling § PlanConfig.json / Plan.json 핵심 필드](../04-gatling-integration/README.md) 참조 | (Gatling 측 — schema 직접 매핑 X) |
| (8) | **`queries` 측정 지표** | Prometheus PromQL 목록 + `name` + `unit`. **응답 레이턴시는 Prometheus query 후보에 넣지 않고 Gatling `simulation.log` → `stats.json` 경로로 집계**. **두 계층으로 구성**: (A) NestJS `/metrics` — `http_request_rate`·`http_error_rate`·`event_loop_lag`·`gc_duration`, job 필터 `job=~"nest-.*"`, counter rate 윈도우 `[2s]`. (B) cAdvisor — `node_cpu`(`container_cpu_usage_seconds_total`, rate 윈도우 `[4s]`)·`node_memory`(`container_memory_rss`), 필터 `job="cadvisor",name=~"realticket_nest.*"`. cAdvisor는 고부하 시에도 컨테이너 외부에서 수집하므로 scrape 신뢰도가 높음 | `queries[]` |
| (9) | **`hypotheses` PASS/FAIL 기준 (선택)** | candidate vs baseline 비교 식. 가설 없으면 절 자체 미생성 | `hypotheses[]` |
| (10) | **외부 repo 코드 리서치 + 구현 계획 기록** | 사용자 입력 수집 완료 후 Gatling 코드베이스 리서치 에이전트를 read-only 로 호출한다. 에이전트는 repo 상태, 관련 파일, 기본 4종 mode 충족 가능 여부, 커스텀 mode 필요성, PlanConfig 생성 경로, 최소 변경 경로, acceptance check, risk 를 분석한다. 결과를 매니페스트 `implementation_plan.gatling` 에 전부 기록하고 RealTicket/git 작업도 같은 `implementation_plan:` 절에 기록한다. **즉시 구현 X** — 구현은 별도 세션에서 순서대로 실행 | `implementation_plan` |

> **schema 완전성 검증:** 위 10단계 + 아래 § AI 자동 derive 항목 합치면 [00-contracts § Manifest Schema](../00-contracts/README.md) 의 15 core fields + optional `bench_stack`·`context`·`implementation_plan` 모두 채워진다. 누락 의심 시 schema 표 cross-check 필수.
>
> **bundling 금지:** (1a) manifest_id 와 (1b) 비교 변수는 **별도 turn 으로 묻는다** — 한 질문에 합치면 사용자가 manifest_id 만 답하거나 비교 변수만 답해서 한쪽이 누락된다. 마찬가지로 다른 단계도 한 turn 1 질문 원칙.

---

## scenario_mode 확정 게이트

`slots[].scenario_mode` 는 Gatling 실행 계약값(`-PscenarioMode`)이므로 비교 변수 설명에서 AI가 임의 derive하지 않는다.

- 기본 4종 모드(`DYNAMIC`/`STATIC`/`PARALLEL`/`LOGIN_ONLY`)든 커스텀 모드든 사용자 확인 없이 YAML에 기록하지 않는다.
- AI는 후보 mode 이름과 의미를 제안할 수 있지만, 사용자가 명시 승인한 값만 `slots[].scenario_mode` 에 기록한다.
- 사용자가 mode 이름을 확정하지 않으면 `slots[].scenario_mode` 필드는 생략하고, (9) `implementation_plan.gatling.scenario_decisions` 에 "scenario_mode 이름/구현 확정" pending 결정을 기록한다.
- `_example-*.yaml` 의 커스텀 mode 이름이나 기존 기본 mode 이름을 사용자 확인 없이 실제 매니페스트 값으로 전용 금지.

---

## PlanConfig 확정 게이트

`PlanConfig.json` 은 PlanGenerator 입력이며, `Plan.json.stats.simulation_duration_ms` 를 결정한다. 이 값은 `per_run_ms`/`main_booking_ms` 와 `main_booking` region 길이로 이어진다. duration mode 의 실제 1회 시간은 여기에 Gatling Config static wait 와 runner overhead 를 더한 뒤 실행 중 실측으로 보정되므로, PlanGenerator 설정과 Config 대기 설정 출처를 모두 확정해야 한다.

### 사용자에게 반드시 확인할 값

이전 답변에 명시되어 있지 않으면 한 번에 뭉쳐 묻지 말고, 부하 프로필 질문으로 분리해서 수집한다.

| 항목 | 왜 사용자 확인이 필요한가 | PlanConfig 매핑 |
|---|---|---|
| 동시 사용자 수 | 부하 강도와 자연 종료 시간을 직접 바꾼다 | `config.num_users` |
| 유저당 좌석 시도 수 | 요청 수와 collision 가능성을 바꾼다 | `config.seats_per_user` |
| 요청 간격 프로필 | 본예매 압축도와 `simulation_duration_ms` 를 바꾼다. 4452d086 이후 `book` 과 `section_move` 가 같은 간격 프로필을 쓴다 | `request_delay_mean`, `request_delay_min`, `request_delay_skew` |
| 좌석 fixture / 섹션 구조 | 수용량, section 이동 가능성, 충돌 양상을 바꾼다. `book` 은 현재 section 안에서만 좌석을 선택하므로 section별 수용량도 확인한다 | `sections[].col_len`, `sections[].seats` |
| seed 정책 | 비교 슬롯 간 동일 Plan 재현성을 결정한다 | `config.seed` |
| section 이동 수와 이동 대상 전략 | section 이동 비교 실험이면 핵심 부하 모델이다. 별도 section 이동 간격은 묻지 않는다 | `section_move_count`, `section_move_target_strategy` |

### AI가 derive하거나 기본 제안할 수 있는 값

- `section_move_count=max(1, floor(seats_per_user / 2))`: 사용자가 별도 값을 주지 않은 경우의 기본 제안. section 이동을 명시적으로 제외한 smoke/no-move 시나리오만 `0` 으로 override 가능.
- `section_move_target_strategy=round_robin`: section별 분산을 deterministic 하게 유지하려는 경우. 사용자가 랜덤 분산을 원하면 `random`.
- `section_move` 간격: 별도 derive 대상이 아니다. PlanGenerator 4452d086 이후 section 이동은 `book` 과 같은 `request_delay_*` 이벤트 큐에서 인터리브되므로 `section_move_delay_*` 를 질문하거나 `context.plan_config` 에 신규 기록하지 않는다.
- `seed`: 사용자가 특정 seed 를 주지 않으면 `manifest_id` 에서 deterministic seed 를 제안하고, 제안값을 `context.plan_config` 에 기록한다. 비교 슬롯은 같은 seed 를 사용한다.
- `snapshot_interval=500`, `network_delay=50`: 별도 측정 의도가 없으면 Gatling 기본값 유지.
- `no_collision=true`: 충돌 자체가 측정 대상이 아니면 noise 차단 기본값으로 제안한다. 충돌/재시도 동작을 측정하려면 사용자 확인 후 `false`.
- `request_delay_min` / `request_delay_skew`: 사용자가 평균만 준 경우 평균 대비 무리 없는 하한·분포를 제안하되, 최종값은 `context.plan_config` 에 남긴다.

### 기록 의무

매니페스트 생성 시 `context.plan_config` 는 "기존 기본값 사용" 같은 단일 문장으로 끝내지 않는다. 최소한 다음을 포함한다.

- 사용자 확인값: `num_users`, `seats_per_user`, 요청 간격, 좌석 fixture, seed 정책, section_move 설정
- AI derive값: 각 필드와 근거
- 미확정값: 구현 세션에서 PlanGenerator 실행 전 다시 물어야 할 항목
- 구현 작업: `implementation_plan.gatling.change_plan` 에 `PlanConfig.json` 생성/수정, `PlanGenerator.py --selftest`, `Plan.json stats.simulation_duration_ms > 0` 확인을 포함

PlanConfig 게이트가 미확정이면 PlanGenerator 실행 계획을 `done: true` 로 표시하지 않는다.

---

## AI 자동 derive 항목

사용자에게 묻지 않고 AI 가 자동으로 채우는 필드 — 기본값을 따른다. 사용자가 명시한 경우만 override.

| 필드 | 기본값 / derive 규칙 |
|------|---------------------|
| `run_id_prefix` | `= manifest_id` (관례 — 명시적 다른 값 요청 없으면) |
| `max_failures` | `2` (m1 기본 정책 — 사용자 별도 요청 없으면) |
| `prom_url` | `http://192.168.138.2:9090` (VM 고정) |
| `prom_step` | `1s` |
| `reset_path` | `/booking/init/:eventId` |
| `plan_path` | `app/src/gatling/resources/Plan.json` (Gatling repo 관례 경로) |
| `slots[].targetUrl` | **1-슬롯**: `http://192.168.138.2:8080`. **2-슬롯** (β 자동 forced=true): baseline=`http://192.168.138.2:8080` · candidate=`http://192.168.138.2:8081` — **두 슬롯 동일 포트 사용 금지** (β=true 의 nest-candidate 서비스가 8081 에 뜨므로) |
| `slots[].image_tag` | `nest:<manifest_id>-<slot_name>` 관례 — manifest_id 가 (1a) 에서 먼저 확정되어야 derive 가능 |

`per_run` 은 자동 derive 가 아니라 **02-orchestration 이 Plan.json 생성 후 분석용 `main_booking_ms` 로 도출** — iter_meta.json 에만 기록 (매니페스트 yaml 에는 부재). duration mode 의 wall-clock 1회 추정값은 run.sh 가 Config static wait + runner overhead + 실측 rolling average 로 관리한다.

---

## Scenario 설계 원칙

시나리오는 한 번에 하나의 비교 변수만 명확히 측정하도록 설계한다. 사용자가 명시하지 않은 기능 토글은 disabled로 유지한다.

최소 매니페스트는 파이프라인 동작 검증에 집중하고, 전체 매니페스트는 baseline·candidate 슬롯 비교와 `hypotheses:` 판정까지 포함한다.

---

## AI 자동 생성 산출물

위 (1)~(9) 수집 + § AI 자동 derive 항목 적용 완료 후 AI 가 자동으로 생성하는 산출물:

| 산출물 | 위치 | 내용 |
|--------|------|------|
| 매니페스트 본체 | `bench/manifests/<manifest_id>.yaml` | [00-contracts/README.md](../00-contracts/README.md) schema 15 core fields + optional `bench_stack`·`context`·`implementation_plan`·`workflow_state` 충족 |
| Gatling 리서치 기록 | 매니페스트 `implementation_plan.gatling` | repo_state·research_summary·scenario_decisions·change_plan·acceptance_checks·risks |
| 구현 세션 작업 목록 | 매니페스트 `implementation_plan.realticket` / `implementation_plan.git` | bench-stack yml 생성, 브랜치 분기·commit·push, VM build/deploy 절차 |
| 재개 상태 | 매니페스트 `workflow_state` | 실행 전 작업의 현재 위치(`current_task_ref`), 마지막 완료, 다음 행동 |

다음 산출물은 매니페스트 작성 세션이 아니라 **구현 세션**에서 생성한다: Gatling `bench/<manifest_id>` 브랜치 코드, RealTicket `bench/<manifest_id>/meta` 및 슬롯 브랜치, `bench-stack/<manifest_id>.yml`, Plan.json, 외부 repo commit/push.

---

## 실행 전 재개 상태 운영

`workflow_state` 는 매니페스트 작성 이후부터 `run.sh` 실행 전까지 AI가 관리한다. 목적은 대화 기록 없이도 새 세션이 매니페스트 파일만 읽고 다음 작업을 이어가는 것이다.

운영 순서:

1. 매니페스트 생성 직후 `workflow_state.status: implementing` 으로 초기화하고, `current_task_ref` 를 첫 미완료 작업(예: `implementation_plan.gatling.change_plan[G1]`)에 맞춘다.
2. 구현 세션에서 작업 하나를 끝낼 때마다 해당 `done: true` 와 `workflow_state.last_completed`·`next_action` 을 함께 갱신한다.
3. 막히면 `status: blocked`, `next_action` 에 필요한 확인/명령을 구체적으로 적고, 근거는 `handoff_notes` 에 남긴다.
4. 실행 전 작업이 모두 끝나면 `implementation_plan.status: completed`, `workflow_state.status: ready_to_run`, `current_task_ref: "run.sh preflight"`, `next_action: "BENCH_PREFLIGHT_ONLY=1 bash areas/02-orchestration/run.sh bench/manifests/<manifest_id>.yaml"` 로 둔다.
5. `run.sh` 시작 후에는 매니페스트에 iteration 진행률을 쓰지 않는다. 실행 중 상태 확인은 `bench/results/<manifest_id>/<run_id>/progress.json` 과 RUNNING/COMPLETED/FAILED 마커를 사용한다.

---

## 매니페스트 등급

| 등급 | 목적 | 특징 |
|------|------|------|
| **최소** | 파이프라인 동작 검증 | `slots` 1개·`iterations` 2~3·`queries` ≥ 1·`hypotheses` 없음 |
| **전체** | 본격 비교 측정 | `slots` 2개·`iterations` ≥ 5 또는 `duration: 6h`·`queries` ≥ 3·`hypotheses` 절 포함 |

두 등급 모두 [00-contracts/README.md](../00-contracts/README.md) schema의 required(✓) 필드는 빠짐없이 채워야 한다.

---

## 운영 정책

- **사용자가 명시하지 않은 토글은 disabled** — α/β/γ/δ 중 사용자가 묻지 않은 차원을 AI 재량으로 활성화 금지
- **slots ≤ 2** — 동시 부하 금지 (Lock #3)
- **매니페스트 작성을 사용자에게 직접 편집 요청 금지** — AI가 수집·생성 주체

---

## 가설 절 패턴 (m2 이후)

매니페스트 `hypotheses:` 필드의 권장 형식:

```yaml
hypotheses:
  - id: H1
    label: "candidate가 baseline 대비 p95 latency 30% 감소"
    metric: p95_response_time         # Gatling stats 기반 metric 또는 queries[].name 중 하나
    direction: lower_is_better
    slot_compare: candidate_vs_baseline
    threshold: 0.30
    pass_when: "improvement >= threshold"
```

가설 판정은 `summarize.py`(03-analysis)가 slot × request_type 레이턴시 표를 생성한 후 본 절을 읽어 PASS/FAIL 판정한다. **m1 dry-run에는 `hypotheses:` 미포함이 정상** — 파이프라인 검증 목적이므로 가설 섹션 미생성이 예상 동작.

---

## AI 작업 지침

### AI가 수행하는 행동

1. (1a)·(1b)·(2)~(10) 단계를 **각 단계 1 질문 원칙**으로 순서대로 질문하여 답변 수집 — bundling 금지. 사용자가 명시 안 한 항목은 § AI 자동 derive 항목과 § PlanConfig 확정 게이트의 규칙에 따라 derive 하거나 질문한다.
2. (2) 슬롯 2개 답변 받으면 즉시 β=true forced + targetUrl 8080/8081 자동 분리. (3) 에서 β 를 사용자에게 다시 묻지 않음
3. `scenario_mode` 는 Gatling `-PscenarioMode` 실행 계약값이므로 사용자 확인 없이 기록하지 않음. 미확정이면 필드 생략 + `implementation_plan.gatling.scenario_decisions` pending 결정으로 남김
4. 수집 완료 후 schema cross-check ([00-contracts § Manifest Schema](../00-contracts/README.md)) — 15 core fields 누락 여부 검증
5. 수집 완료 후 Gatling repo 를 read-only 로 조사한다. 최소 확인값: `git status --porcelain`, 현재 브랜치, `origin/main` 최신 커밋, 관련 Java/PlanGenerator/PlanConfig/Gradle 파일, 기본 4종 mode 로 충분한지 여부.
6. **매니페스트 YAML 생성 시 `context:` + `implementation_plan:` + `workflow_state:` 절을 반드시 포함.** `context:` 에는 (1b) 비교 변수·슬롯 설명·region 흐름·PlanConfig 확정값/derive값/미확정값을 기록. `implementation_plan.gatling` 에는 리서치 결과 전체를 `research_summary`·`repo_state`·`scenario_decisions`·`change_plan`·`acceptance_checks`·`risks` 로 기록하고 `status: "pending"` 으로 초기화한다. `change_plan` 에는 PlanConfig 생성/수정과 PlanGenerator 실행 검증 작업이 반드시 포함되어야 한다. `workflow_state` 는 첫 미완료 구현 작업을 가리키게 둔다. **이 세션에서 외부 repo 코드 직접 구현 금지** — 계획 기록만.
7. 사용자에게 생성된 매니페스트 YAML을 검토용으로 제시

### 수정 허용 범위

- 가설 절 패턴 확장 — m2에서 hypotheses 형식이 진화할 때
- 결정 순서 (1)~(9) 갱신 — 새 기능 토글 추가 시
- § AI 자동 derive 항목 기본값 갱신 — 환경 변경 (VM IP 등) 시
- 변경 시 [00-contracts/README.md](../00-contracts/README.md) schema 와 동기 갱신 필수

### 행동 금지

- schema 15 core fields + optional objects 정의를 본 파일에 재진술 금지 — [00-contracts/README.md](../00-contracts/README.md) 로 link만
- 사용자가 명시하지 않은 토글을 AI 재량으로 활성화 금지
- `per_run` 을 사용자에게 묻거나 매니페스트 yaml 에 기록 금지 — Plan.json 도출 단일 진실
- 매니페스트 작성을 사용자 직접 편집 방식으로 진행 금지
- **`implementation_plan:` 에 기록된 외부 repo 코드 변경을 매니페스트 작성 세션에서 즉시 구현 금지** — 구현 세션에서 task 목록을 순서대로 실행하는 것이 올바른 흐름
- `run.sh` 실행 중 iteration 진행률을 `workflow_state` 에 중복 기록 금지 — 벤치마크 실행 중 상태는 결과 디렉토리 산출물이 단일 진실
