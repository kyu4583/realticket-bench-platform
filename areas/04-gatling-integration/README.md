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
| 2 | `scenarioMode` | enum (`DYNAMIC`\|`STATIC`\|`PARALLEL`\|`LOGIN_ONLY`\|`SECTION_A`\|`SECTION_B`) | `LOGIN_ONLY` | 시나리오 모드 6개 분기 |
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

```json
{
  "config": { "num_users": 500, "seed": 4586, ... },
  "regions": [
    { "name": "booking", "duration_ms": 300000, "actions": [{"kind": "book_seats"}] }
  ]
}
```

### Plan.json (PlanGenerator.py 출력) — 핵심 필드

| 경로 | 타입 | 의미 |
|------|------|------|
| `stats.regions[].name` | string | region 식별자 (Lock #4 단일 진실 — 03-analysis 슬라이스 키) |
| `stats.regions[].start_ms` / `end_ms` | int | region 절대 시간 (PlanGenerator가 누적 계산) |
| `stats.regions[].actions[].kind` | enum | `wait`\|`subscribe`\|`book_seats`\|`section_move`\|`confirm`\|`login` |
| `requests[].region` | string | 요청이 속한 region (Lock #4 — 03-analysis region 슬라이싱) |

---

## prepare_gatling_branch() 수행 순서

| 단계 | 명령 | 비고 |
|------|------|------|
| (1) 브랜치 분기 | `git -C <gatling_dir> checkout -b bench/<manifest_id> origin/main` | 이미 존재하면 `git checkout bench/<manifest_id>` |
| (2) 코드 수정 + commit | `git -C <gatling_dir> add <files> && git commit -m "bench: <manifest_id> — <요약>"` | AI가 매니페스트 의도에 맞게 수정 |
| (3) 실행 | `(cd <gatling_dir> && ./gradlew gatlingRunAndArchive -P...)` | 본 브랜치 체크아웃 상태 유지 |
| (4) main 복귀 | `git -C <gatling_dir> checkout main` | 브랜치 삭제 X — 영구 보존 |

모든 명령은 `git -C` 패턴 — 본 repo working dir 유지.

---

## 불변 조건

- gatling main 영구 변경 금지 — 영구 변경은 외부 PR 별도 흐름 + Tracking bump
- 화이트리스트에 없는 -P 키 주입 금지 (silent no-op)
- 외부 repo region을 재정의 금지 (Lock #4 위배)
- 외부 repo README/CLAUDE.md 수정 금지

---

## 함정 체크리스트

**행동 전 반드시 확인:**

- `Plan_default_seed4586.json` snapshot 존재 여부 — OneDrive 동기화 잔재로 누락 가능
  ```bash
  git -C <gatling_dir> restore app/src/gatling/resources/tests/snapshots/
  ```
- PlanGenerator.py selftest 3케이스 통과 여부
  ```bash
  (cd <gatling_dir>/app/src/gatling/resources && python PlanGenerator.py --selftest)
  ```
- `-PscenarioMode` 미주입 시 LOGIN_ONLY 폴백 — run_gatling 호출 전 반드시 명시
- Plan.json seed override 필수 — 동일 seed → 동일 Plan.json (비교 벤치마크 noise 차단)

---

## AI 작업 지침

### AI가 수행하는 행동

**매니페스트 시작 시:**
1. gatling repo 현재 상태 확인 (`git -C <dir> status --porcelain`)
2. `bench/<manifest_id>` 브랜치 분기
3. 매니페스트 의도에 맞는 코드 변경 (PlanConfig.json regions, -P 키 등)
4. commit + origin push

**매니페스트 실행 중:**
- 본 브랜치 체크아웃 상태 유지 + `./gradlew gatlingRunAndArchive -P<keys>` 호출

**매니페스트 종료 시:**
- `git checkout main` 복귀 + 브랜치 삭제 금지

### Tracking 갱신 시점

- gatling main에 변경이 생긴 경우 변경된 -P 키/스키마/클래스 표에 반영
- 최신 커밋은 `git -C <gatling-repo> log origin/main -1 --format="%h %ad %s" --date=short` 로 동적 확인

### 행동 금지

- gatling main 영구 변경 금지
- 화이트리스트 외 -P 키 주입 금지
- 외부 repo README/CLAUDE.md 수정 금지
