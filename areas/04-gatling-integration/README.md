# 04-gatling-integration — Gatling repo 인터페이스 · 브랜치 격리

> Tracking: gatling repo `main` — 동적 확인: `git -C <gatling-repo> log origin/main -1 --format="%h %ad %s" --date=short`

본 영역은 외부 Gatling repo(별도 git)와 본 repo 사이의 계약을 lock한다. 본 파일은 모듈 지도·변경 원칙·과거 함정·브랜치 격리를 다룬다.

외부 gatling repo의 README/CLAUDE.md는 수정하지 않는다 — bench는 해석/원칙만.

---

## Gatling repo 경로

```
../gatling-practice/realticket-gatling-simulations
```

- branch: `main` (동적 확인)
- drift 점검: `git -C ../gatling-practice/realticket-gatling-simulations log origin/main -1 --format="%h %ad %s" --date=short`

---

## -P 키 표 (8개)

> 출처: 외부 repo `app/build.gradle` `benchPropertyKeys` 화이트리스트 + `Config.java` parseEnum/parseString/parseInt 호출.
> 화이트리스트에 없는 -P 키는 silent no-op — 가장 흔한 함정.

| # | 키 | 타입 | default | 의미 |
|---|------|------|---------|------|
| 1 | `subscriptionType` | enum (`SSE`\|`WS`) | `SSE` | 구독 방식 — SseHandler vs WsHandler 디스패치 |
| 2 | `scenarioMode` | enum (`DYNAMIC`\|`STATIC`\|`PARALLEL`\|`LOGIN_ONLY`) + 커스텀 | `LOGIN_ONLY` | 기본 4종 고정. 매니페스트 목적에 따라 bench/<manifest_id> 브랜치에서 Gatling 코드 수정으로 커스텀 모드 추가 가능 (일회성 — main 영구 변경 금지) |
| 3 | `targetUrl` | string | `192.168.138.2:8080` | 부하 대상 URL |
| 4 | `planPath` | string (path) | null → classpath fallback | Plan.json 절대/상대 경로 |
| 5 | `targetEvent` | int | `1` | 부하 대상 RealTicket eventId |
| 6 | `dynamicUserCount` | int | `200` | DYNAMIC 모드의 동시 사용자 수 |
| 7 | `fixedBookingAmount` | int | `4` (음수면 랜덤) | 1 사용자가 시도하는 좌석 수 |
| 8 | `maxRetryInBookingConflict` | int | `100` | booking 충돌 재시도 횟수 상한 |

> **검증:** 시뮬레이션 시작 시 콘솔에 `=== Bench -P injection ===` + `EFFECTIVE_CONFIG {...}` 1줄 출력. 누락 시 시뮬레이션 미시작 의심.
>
> **`-PscenarioMode` 미주입 시 LOGIN_ONLY 폴백** — 의도한 부하가 실행되지 않는 가장 흔한 실수.

---

## PlanConfig.json / Plan.json 핵심 필드

region 모델 정의는 [00-contracts/README.md](../00-contracts/README.md) § Region·Slot·Iteration 모델 참조.

### PlanConfig.json (입력)

현재 PlanGenerator 입력은 `config` + `sections` 구조다. 과거의 `regions/actions` 입력 모델은 사용하지 않는다.

```json
{
  "config": {
    "num_users": 500,
    "seats_per_user": 2,
    "seed": 4586,
    "snapshot_interval": 500,
    "network_delay": 50,
    "request_delay_mean": 2000,
    "request_delay_min": 500,
    "request_delay_skew": 1,
    "no_collision": true,
    "section_move_count": 1,
    "section_move_target_strategy": "round_robin"
  },
  "sections": [
    { "col_len": 50, "seats": [1, 1, 1, 1] }
  ]
}
```

PlanConfig는 매니페스트 schema의 core field가 아니지만, PlanGenerator 실행 전에 확정되어야 하는 Gatling 입력 계약이다. 사용자 수·좌석 수·요청 간격·좌석 fixture는 부하 모델 자체를 바꾸므로 AI가 임의로 숨겨진 기본값을 쓰면 안 된다.

> **PlanGenerator 4452d086 계약:** `section_move_delay_*` 입력은 폐기됐다. `book` 과 `section_move` 는 하나의 이벤트 큐에서 `request_delay_mean` / `request_delay_min` / `request_delay_skew` 를 공통 간격으로 사용하며, 유저의 `book` 요청은 현재 section 안의 좌석만 선택할 수 있다.

### PlanConfig 설정 책임 분류

| 필드 | 책임 | 운영 규칙 |
|---|---|---|
| `num_users` | 사용자 확인 필수 | 동시 사용자 수. 답변이 없으면 PlanGenerator 실행 전 질문한다. |
| `seats_per_user` | 사용자 확인 필수 | 요청 수와 좌석 점유량을 바꾼다. smoke 검증만 예외적으로 1~2를 제안 가능. |
| `request_delay_mean` / `request_delay_min` / `request_delay_skew` | 사용자 확인 + AI 보조 | 평균은 반드시 확인. min/skew는 평균과 실험 목적을 근거로 제안하고 기록한다. 이 간격은 `book` 과 `section_move` 에 공통 적용된다. |
| `sections` | 사용자 확인 필수 | 실제 event 좌석 fixture를 쓸지, synthetic fixture를 쓸지 확정한다. section 이동 실험이면 최소 2 section 필요. `book` 은 현재 section 안에서만 좌석을 고르므로, target strategy 로 방문하는 section 별 수용량이 부하를 감당하는지 확인한다. |
| `seed` | 확인 또는 deterministic derive | 사용자가 지정하지 않으면 `manifest_id` 기반 고정 seed를 제안한다. baseline/candidate는 같은 seed를 사용한다. |
| `no_collision` | 목적 기반 확인 | 충돌이 측정 대상이 아니면 `true`를 제안한다. 충돌/재시도 측정이면 `false` 여부를 확인한다. |
| `section_move_count` | 목적 기반 확인 + 기본 제안 | 유저당 section 이동 횟수. section 이동이 비교 변수면 사용자 확인 필수. 별도 값이 없으면 `max(1, floor(seats_per_user / 2))` 를 제안한다. section 이동을 제외한 smoke/no-move 시나리오만 `0` 으로 override 가능. |
| `section_move_target_strategy` | 사용자 확인 + AI 보조 | 이동 횟수가 0으로 override된 경우만 무시. 이동이 있으면 `round_robin`/`random` 의도를 확인한다. 별도 section 이동 간격 필드는 없으며, 이동 간격은 `request_delay_*` 를 따른다. |
| `snapshot_interval` / `network_delay` | 기본값 가능 | 별도 실험 의도가 없으면 각각 500/50 유지. 변경 시 이유를 `context.plan_config`에 기록한다. |

### Plan.json (PlanGenerator.py 출력) — 핵심 필드

| 경로 | 타입 | 의미 |
|------|------|------|
| `stats.simulation_duration_ms` | int | 전체 시뮬레이션 시간 ms. `book` 과 `section_move` 를 포함한 마지막 요청 시각 기준 |
| `stats.num_users` / `seats_per_user` | int | 시뮬레이션 파라미터 |
| `requests[].type` | string | `book` \| `section_move` |
| `requests[].time_ms` | int | 요청 발생 시각 (시뮬레이션 기준 ms) |
| `requests[].section` | int | `book` 은 현재 section, `section_move` 는 이동 전 section |
| `requests[].target_section` | int? | `section_move` 전용 이동 대상 section |

---

## Gatling 구현 세션 수행 순서

| 단계 | 명령 | 비고 |
|------|------|------|
| (1) 브랜치 분기 | `git -C <gatling_dir> checkout -b bench/<manifest_id> origin/main` | 이미 존재하면 `git checkout bench/<manifest_id>` |
| (2) 코드 수정 + commit | `git -C <gatling_dir> add <files> && git commit -m "bench: <manifest_id> — <요약>"` | 매니페스트 `implementation_plan.gatling.change_plan` 순서대로 수정 |
| (3) 실행 | `(cd <gatling_dir> && ./gradlew gatlingRunAndArchive -P...)` | 본 브랜치 체크아웃 상태 유지 |
| (4) main 복귀 | `git -C <gatling_dir> checkout main` | 브랜치 삭제 X — 영구 보존 |

모든 명령은 `git -C` 패턴 — 본 repo working dir 유지.

---

## 불변 조건

- gatling main 영구 변경 금지 — 영구 변경은 외부 PR 별도 흐름 + Tracking bump
- 화이트리스트에 없는 -P 키 주입 금지 (silent no-op)
- 외부 repo README/CLAUDE.md 수정 금지

---

## 함정 체크리스트

**행동 전 반드시 확인:**

- `Plan_default_seed4586.json` snapshot 존재 여부 — OneDrive 동기화 잔재로 누락 가능
  ```bash
  git -C <gatling_dir> restore app/src/gatling/resources/tests/snapshots/
  ```
- PlanConfig 확정 게이트 완료 여부 — `num_users`, `seats_per_user`, 요청 간격, 좌석 fixture, seed, section_move 설정이 `context.plan_config` 에 기록되어 있어야 함
- PlanConfig에 `section_move_delay_mean_ms` / `section_move_delay_min_ms` / `section_move_delay_skew` 를 새로 넣지 않았는지 확인 — 4452d086 이후 PlanGenerator 입력 계약이 아님
- section 이동 실험이면 target strategy 로 방문하는 section 별 좌석 수가 `no_collision=true` 계획을 자연 종료시킬 만큼 충분한지 확인
- PlanGenerator.py selftest 3케이스 통과 여부
  ```bash
  (cd <gatling_dir>/app/src/gatling/resources && python PlanGenerator.py --selftest)
  ```
- `-PscenarioMode` 미주입 시 LOGIN_ONLY 폴백 — run_gatling 호출 전 반드시 명시
- Plan.json seed override 필수 — 동일 seed → 동일 Plan.json (비교 벤치마크 noise 차단)

---

## region (시뮬레이션 단계) ↔ Gatling Config 대기 설정 매핑

매니페스트 시나리오는 여러 **단계(region)** 로 구성된다 — 예: "입장 권한 확인 → 구독 → 본예매".
**region 정의는 매니페스트 yaml에 직접 명시하지 않는다** — Gatling 시뮬레이션 코드가 단계 흐름의 단일 진실. 단계 간 대기 시간은 Gatling `Config.java`의 `ENABLE_WAITING_*` boolean + `WAITING_*_MILLIS` int 쌍으로 제어한다.

> 용어 주의: 본 region은 **시뮬레이션 단계 개념**이며, 과거 PlanGenerator의 region(시간 윈도우, 폐기됨)과 무관하다.

### 기본 단계 대기 설정 (Config.java)

| Config 설정 쌍 | 의미 | 자연어 매핑 |
|---|---|---|
| `ENABLE_WAITING_BEFORE_SUBS` + `WAITING_BEFORE_SUBS_MILLIS` | 권한 확인 → 구독 사이 대기 | "권한 확인과 구독 사이에 X초 대기", "구독 전 X초 대기" |
| `ENABLE_WAITING_AFTER_SUBS` + `WAITING_AFTER_SUBS_MILLIS` | 구독 → 본예매 사이 대기 | "구독과 본예매 사이에 X초 대기", "구독 후 X초 대기" |
| `ENABLE_WAITING_BETWEEN_ACTIONS` + `WAITING_SECOND_BETWEEN_ACTIONS_MILLIS` | 본예매 액션(좌석 점유·section 이동·결제) 사이 대기 | "각 액션 사이에 X초 간격" |

기본값은 모두 `ENABLE_*=false`. 매니페스트별 timing 요구가 있으면 `bench/<manifest_id>` 브랜치에서 `true` + 원하는 ms 값으로 override.

### AI 매핑 절차

매니페스트 시작 시 사용자가 region 구성과 단계 간 딜레이를 자연어로 알려주면 AI는:
1. 위 표의 자연어 매핑에 해당하는 Config 설정으로 변환
2. `implementation_plan.gatling.change_plan` 에 `Config.java` boolean = true + ms 값 변경 계획 기록
3. 표에 없는 새 단계 경계의 딜레이가 필요하면 새 `ENABLE_WAITING_*` + `WAITING_*_MILLIS` 추가 + 시뮬레이션 코드(Static·DYNAMIC 등) 분기 적용 계획 기록

### 새 단계·새 설정 추가 절차 (매니페스트 브랜치 한정)

기본 3개 쌍으로 표현할 수 없는 region 경계의 딜레이가 필요한 경우:
1. `bench/<manifest_id>` 브랜치에서 `Config.java`에 `ENABLE_WAITING_<NEW>` boolean + `WAITING_<NEW>_MILLIS` int 추가
2. 시뮬레이션 코드의 해당 단계 진입/이탈 지점에 분기 적용
3. main 영구 변경 금지 — 매니페스트 브랜치에만 격리

### analyze 측 phases.json 연동

region 구성과 단계 간 대기가 결정되면 분석 측도 같은 단계 경계로 Prometheus 메트릭을 슬라이싱한다.
**책임 분담:**
- 02-orchestration 가 매니페스트의 region 결정 + Config 스냅샷에서 `phases.json` (run_dir 1개) 을 derive 작성
- 03-analysis `prom_query.py` 가 `phases.json` 을 읽어 phase 별 `prom_metrics.json` 생성
- 03-analysis `summarize.py` 가 SUMMARY.md 에 slot × phase × query 표 출력

phases.json 스키마는 [00-contracts § phases.json 스키마](../00-contracts/README.md) 참조.

---

## bench_stack ↔ Gatling 연동 규칙

매니페스트의 `bench_stack` 토글이 활성화되면 Gatling 코드에도 대응 변경이 필요하다.
**bench_stack 토글 확인은 매니페스트 작성 세션의 Gatling read-only 리서치 때 반드시 수행하고, 실제 변경은 구현 세션에서 수행한다.**

| 토글 | Gatling 코드 의무 변경 |
|------|----------------------|
| `alpha_test_account: true` | `Config.java`(또는 동등 설정)에서 `TEST_ACCOUNT_ALREADY_STORED` 옵션 활성화. 커스텀 시나리오 모드에서도 로그인 요청 생략 필수. |
| `beta_dual_slots: true` | 변경 없음 (포트 8081 서비스 추가는 bench-stack yml 측 — Gatling은 `-PtargetUrl`로 분기) |
| `gamma_sentinel: true` | 변경 없음 (Redis Sentinel 구성은 stack 측) |
| `delta_autoscaler: true` | 변경 없음 (autoscaler 서비스는 stack 측) |

### `alpha_test_account: true` 상세

> **이유:** 테스트 계정은 DB에 pre-loaded — 로그인 요청을 보내면 세션이 오염되어 예약 흐름이 오동작한다.

체크리스트:
- [ ] `Config.java`(또는 설정 클래스)에서 `TEST_ACCOUNT_ALREADY_STORED = true` 확인 → 기본 4종 모드(`DYNAMIC`/`STATIC`/`PARALLEL`/`LOGIN_ONLY`)에서 로그인 자동 비활성화 (별도 코드 변경 불필요)
- [ ] 커스텀 시나리오 모드 구현 시 로그인 요청 생략 필수 (커스텀 코드는 플래그 적용 범위 밖일 수 있으므로 직접 확인해야 함)

---

## AI 작업 지침

### 커스텀 시나리오 모드 구현 원칙

한 슬롯이 기본 4종 모드를 사용하고 다른 슬롯이 커스텀 모드를 사용할 때, **커스텀 모드는 같은 매니페스트의 기본 모드를 베이스로 필요최소한의 변경만** 가한다.

> **이유:** 두 슬롯의 코드 경로 차이를 측정 변수로만 좁혀야 벤치마크 비교가 신뢰성을 가진다. 커스텀 모드가 기본 모드와 다른 코드 경로를 많이 가지면 측정 noise가 늘어난다.
>
> **적용:** 기본 모드(예: `PARALLEL`) 코드를 복사 후 비교 변수에 해당하는 로직만 수정. 로그인·Plan 파싱·사용자 주입 등 공통 흐름은 그대로 유지.

---

### AI가 수행하는 행동

**매니페스트 작성 세션 (read-only):**
1. gatling repo 현재 상태 확인 (`git -C <dir> status --porcelain`, 현재 브랜치, `origin/main` 최신 커밋)
2. 관련 파일을 읽어 각 슬롯의 동작을 기본 4종으로 충족할 수 있는지 슬롯별로 독립 판단:
   - 기본 4종으로 충분한 슬롯 → 해당 mode 그대로 사용
   - 기본 4종으로 부족한 슬롯 → 해당 슬롯만 커스텀 모드 구현 계획 작성 (위 원칙 적용)
   - 두 슬롯 모두 커스텀이 필요할 수도, 하나만 필요할 수도 있음
3. `implementation_plan.gatling` 에 `research_summary`, `repo_state`, `scenario_decisions`, `change_plan`, `acceptance_checks`, `risks` 를 기록
4. 외부 Gatling repo 파일 수정, 브랜치 분기, PlanGenerator 실행, commit, push 금지

**구현 세션:**
1. `implementation_plan.gatling.change_plan` 을 읽고 `bench/<manifest_id>` 브랜치 분기
2. 매니페스트 의도에 맞는 코드 변경 (ScenarioMode, Config.java, PlanConfig/PlanGenerator 입력 등)
3. `context.plan_config` 의 확정값으로 `PlanConfig.json` 생성/수정. 미확정 항목이 있으면 사용자에게 먼저 질문하고, 매니페스트의 `context.plan_config` 와 `workflow_state` 를 갱신
4. PlanGenerator 실행 → Plan.json 생성
5. acceptance_checks 수행
6. commit + origin push
7. 매니페스트의 `implementation_plan.gatling.change_plan[].done` 과 `workflow_state` 갱신
8. Gatling 쪽 작업이 모두 끝나면 다음 미완료 RealTicket/git 작업을 `workflow_state.current_task_ref` 와 `next_action` 에 기록한다. 전체 실행 전 작업이 끝났을 때만 최상위 `implementation_plan.status: completed` 로 갱신

**매니페스트 실행 중:**
- 본 브랜치 체크아웃 상태 유지 + `./gradlew gatlingRunAndArchive -P<keys>` 호출
- 각 iter 종료 후 Gatling 기본 HTML report 최신 디렉토리(`app/build/reports/gatling/*`)를 플랫폼 결과 디렉토리의 `iter-N-<slot>/gatling-report/` 로 복사
- 같은 iter 디렉토리에 `gatling-report-source.txt` 를 남겨 원본 report 디렉토리 경로를 추적

**매니페스트 종료 시:**
- `git checkout main` 복귀 + 브랜치 삭제 금지

### Tracking 갱신 시점

- gatling main에 변경이 생긴 경우 변경된 -P 키/스키마/클래스 표에 반영
- 최신 커밋은 `git -C <gatling-repo> log origin/main -1 --format="%h %ad %s" --date=short` 로 동적 확인

### 행동 금지

- gatling main 영구 변경 금지
- 화이트리스트 외 -P 키 주입 금지
- PlanConfig 확정값 없이 PlanGenerator 실행 금지
- 외부 repo README/CLAUDE.md 수정 금지
