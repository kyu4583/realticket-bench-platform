# 01-planning — 매니페스트 수집 흐름

본 영역은 AI가 사용자로부터 매니페스트를 지능적으로 수집하는 방법과 순서를 정의한다. schema 정의는 [00-contracts/README.md](../00-contracts/README.md)에 단일 진실로 lock되어 있으며, 본 파일은 그것을 link로만 참조한다.

---

## 매니페스트 수집 흐름 9단계

사용자가 "매니페스트 시작하자" 또는 동등한 자연어 명령을 내리면 AI는 다음 순서로 진행한다.

| 단계 | 질문/입력 대상 | AI 행동 | schema 매핑 |
|------|---------|---------|------------|
| (1a) | **manifest_id (필수 입력)** | 사용자에게 매니페스트 식별자 (영문 kebab-case, 예: `sse-reconnect-vs-patch`)를 **별도 질문으로** 받는다. AI 추측 derive 금지 — 명시 입력 강제. image_tag·브랜치명 등이 이 값에서 derive 되므로 가장 먼저 확정 | `manifest_id` |
| (1b) | **비교 변수 1개 (필수 입력)** | 이번 매니페스트가 측정할 단일 비교 차원 확인 (예: SSE 아키텍처 비교 · Sentinel 적용 유무 · 캐싱 적용 전후). (1a) 와 별도 질문으로 받음 — 한 답변으로 합치지 말 것 | (직접 매핑 X — 후속 단계의 컨텍스트) |
| (2) | **baseline·candidate 슬롯 정의** | `slots[].name` + `targetUrl` + `image_tag`. 슬롯 ≤ 2 (Lock #3). **슬롯 2개면 β=true 강제 + targetUrl baseline=8080·candidate=8081 자동 분리** (§ AI 자동 derive 참조 — 두 슬롯 동일 포트 금지). `scenario_mode` 는 기본 4종/커스텀 여부와 무관하게 사용자 확인 없이 기록 금지 — 아래 § scenario_mode 확정 게이트 참조 | `slots[]` |
| (3) | **docker-stack 4 기능 토글** | α(테스트 계정 사전 로그인 yes/no) · **β(nest 슬롯 개수 — (2) 슬롯 정의에서 양방향 자동 derive: 슬롯 2개면 β=true 강제, 1개면 β=false 강제 — 사용자에게 따로 묻지 않음)** · γ(Sentinel·autoscaling) · δ(autoscaler). 사용자가 명시 안 한 차원(α/γ/δ)은 disabled. **α=true 활성 시 [04-gatling § bench_stack ↔ Gatling 연동 규칙](../04-gatling-integration/README.md) 강제 — `TEST_ACCOUNT_ALREADY_STORED` 활성화 + 커스텀 시나리오 login 생략을 매니페스트 브랜치에 적용** | `bench_stack` |
| (4) | **region 구성 + 단계 간 대기** | 시나리오 단계 흐름 (예: "권한 확인 → 구독 → 본예매") + 단계 사이 대기 시간을 자연어로 수집 → [04-gatling § region ↔ Gatling Config 대기 설정 매핑](../04-gatling-integration/README.md)으로 변환하여 매니페스트 브랜치 `Config.java` 적용 | (Config 측 — schema 직접 매핑 X) |
| (5) | **실행 모드 + 타이밍** | `iterations` (정수) XOR `duration` (`6h`·`10m`) 선택 + `warmup` + `cooldown` 입력. **`per_run` 은 묻지 않음** — Plan.json 자연 종료 후 02-orchestration 이 `ceil(simulation_duration_ms × 1.1)` 도출 ([00-contracts § per_run 도출 규칙](../00-contracts/README.md)) | `iterations`\|`duration`, `warmup`, `cooldown` |
| (6) | **`event_ids`** | reset 호출할 RealTicket 이벤트 ID 배열 | `event_ids` |
| (7) | **`queries` 측정 지표** | Prometheus PromQL 목록 + `name` + `unit`. 표준 후보: `http_request_rate`, `http_error_rate`, Node process CPU/memory, event loop lag, GC. **응답 레이턴시는 Prometheus query 후보에 넣지 않고 Gatling `simulation.log` → `stats.json` 경로로 집계** | `queries[]` |
| (8) | **`hypotheses` PASS/FAIL 기준 (선택)** | candidate vs baseline 비교 식. 가설 없으면 절 자체 미생성 | `hypotheses[]` |
| (9) | **외부 repo 코드 변경 식별 + 구현 계획 기록** | gatling·RealTicket 의 매니페스트별 일회성 코드 변경 목록을 사용자와 확인 (커스텀 scenario_mode·Config 값·bench-stack yml·source_branch 등). **즉시 구현 X** — 변경 항목을 매니페스트 `implementation_plan:` 절에 task 목록으로 기록. 구현은 별도 세션(구현 세션)에서 순서대로 실행. git untracked 빌드 파일도 여기서 식별·기록 | `implementation_plan` |

> **schema 완전성 검증:** 위 9단계 + 아래 § AI 자동 derive 항목 합치면 [00-contracts § Manifest Schema](../00-contracts/README.md) 의 15 core fields + optional `bench_stack`·`context`·`implementation_plan` 모두 채워진다. 누락 의심 시 schema 표 cross-check 필수.
>
> **bundling 금지:** (1a) manifest_id 와 (1b) 비교 변수는 **별도 turn 으로 묻는다** — 한 질문에 합치면 사용자가 manifest_id 만 답하거나 비교 변수만 답해서 한쪽이 누락된다. 마찬가지로 다른 단계도 한 turn 1 질문 원칙.

---

## scenario_mode 확정 게이트

`slots[].scenario_mode` 는 Gatling 실행 계약값(`-PscenarioMode`)이므로 비교 변수 설명에서 AI가 임의 derive하지 않는다.

- 기본 4종 모드(`DYNAMIC`/`STATIC`/`PARALLEL`/`LOGIN_ONLY`)든 커스텀 모드든 사용자 확인 없이 YAML에 기록하지 않는다.
- AI는 후보 mode 이름과 의미를 제안할 수 있지만, 사용자가 명시 승인한 값만 `slots[].scenario_mode` 에 기록한다.
- 사용자가 mode 이름을 확정하지 않으면 `slots[].scenario_mode` 필드는 생략하고, (9) `implementation_plan.gatling.tasks` 에 "scenario_mode 이름/구현 확정" pending task를 기록한다.
- `_example-*.yaml` 의 커스텀 mode 이름이나 기존 기본 mode 이름을 사용자 확인 없이 실제 매니페스트 값으로 전용 금지.

---

## AI 자동 derive 항목

사용자에게 묻지 않고 AI 가 자동으로 채우는 필드 — 기본값을 따른다. 사용자가 명시한 경우만 override.

| 필드 | 기본값 / derive 규칙 |
|------|---------------------|
| `run_id_prefix` | `= manifest_id` (관례 — 명시적 다른 값 요청 없으면) |
| `max_failures` | `2` (m1 기본 정책 — 사용자 별도 요청 없으면) |
| `prom_url` | `http://192.168.138.2:9090` (VM 고정) |
| `prom_step` | `15s` |
| `reset_path` | `/booking/init/:eventId` |
| `plan_path` | `app/src/gatling/resources/Plan.json` (Gatling repo 관례 경로) |
| `slots[].targetUrl` | **1-슬롯**: `http://192.168.138.2:8080`. **2-슬롯** (β 자동 forced=true): baseline=`http://192.168.138.2:8080` · candidate=`http://192.168.138.2:8081` — **두 슬롯 동일 포트 사용 금지** (β=true 의 nest-candidate 서비스가 8081 에 뜨므로) |
| `slots[].image_tag` | `nest:<manifest_id>-<slot_name>` 관례 — manifest_id 가 (1a) 에서 먼저 확정되어야 derive 가능 |

`per_run` 은 자동 derive 가 아니라 **02-orchestration 이 Plan.json 생성 후 도출** — iter_meta.json 에만 기록 (매니페스트 yaml 에는 부재).

---

## Scenario 설계 원칙

시나리오는 한 번에 하나의 비교 변수만 명확히 측정하도록 설계한다. 사용자가 명시하지 않은 기능 토글은 disabled로 유지한다.

최소 매니페스트는 파이프라인 동작 검증에 집중하고, 전체 매니페스트는 baseline·candidate 슬롯 비교와 `hypotheses:` 판정까지 포함한다.

---

## AI 자동 생성 산출물

위 (1)~(9) 수집 + § AI 자동 derive 항목 적용 완료 후 AI 가 자동으로 생성하는 산출물:

| 산출물 | 위치 | 내용 |
|--------|------|------|
| 매니페스트 본체 | `bench/manifests/<manifest_id>.yaml` | [00-contracts/README.md](../00-contracts/README.md) schema 15 core fields + optional `bench_stack` 충족 |
| docker stack 정의 | `bench-stack/<manifest_id>.yml` (RealTicket repo 매니페스트 ID 브랜치) | base.yml + 활성 토글 patch yq merge |
| Gatling 브랜치 코드 | gatling repo `bench/<manifest_id>` 브랜치 | 일회성 시나리오·PlanConfig 변경 commit |
| RealTicket 브랜치 코드 | RealTicket repo `bench/<manifest_id>` 메타 + 슬롯 브랜치 | yml commit·push |
| VM untracked 파일 | VM `~/web04-RealTicket` 해당 위치 | 빌드에 필요한 git 미추적 파일 적용 |

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

1. (1a)·(1b)·(2)~(9) 단계를 **각 단계 1 질문 원칙**으로 순서대로 질문하여 답변 수집 — bundling 금지. 사용자가 명시 안 한 항목은 § AI 자동 derive 항목의 기본값으로 채움 (질문 X)
2. (2) 슬롯 2개 답변 받으면 즉시 β=true forced + targetUrl 8080/8081 자동 분리. (3) 에서 β 를 사용자에게 다시 묻지 않음
3. `scenario_mode` 는 Gatling `-PscenarioMode` 실행 계약값이므로 사용자 확인 없이 기록하지 않음. 미확정이면 필드 생략 + `implementation_plan` pending task로 남김
4. 수집 완료 후 schema cross-check ([00-contracts § Manifest Schema](../00-contracts/README.md)) — 15 core fields 누락 여부 검증
5. **매니페스트 YAML 생성 시 `context:` + `implementation_plan:` 절을 반드시 포함.** `context:` 에는 (1b) 비교 변수·슬롯 설명·region 흐름·plan_config 메모를 기록. `implementation_plan:` 에는 (9) 에서 식별한 외부 repo 변경을 gatling/realticket/git task 목록으로 기록하고 `status: "pending"` 으로 초기화. **이 세션에서 외부 repo 코드 직접 구현 금지** — task 기록만.
6. 사용자에게 생성된 매니페스트 YAML을 검토용으로 제시

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
