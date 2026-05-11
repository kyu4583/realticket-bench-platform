# realticket-bench-platform — Claude Code Orientation

## READ-FIRST (모든 세션 시작 시 반드시 확인)

### Claude Code 운영 entrypoint

Claude Code에서 benchmark 운영 작업(매니페스트 시작·재개·preflight/run.sh 실행·결과 확인·SUMMARY 해석 보강·외부 repo drift 확인)을 수행할 때는 project skill `realticket-bench-operator`를 먼저 사용한다.

- project skill 위치: `.claude/skills/realticket-bench-operator/`
- 공유 원본: `.agents/skills/realticket-bench-operator/`
- 단일 진실: schema·Lock·외부 repo 계약·결과 구조는 계속 `areas/*/README.md`

skill이 로드되지 않은 환경에서는 `.claude/skills/realticket-bench-operator/SKILL.md`를 직접 읽고 같은 절차를 따른다.

### 7 영역 1급 시민 (rev 2 — 2026-05-02 재정의)

본 프로젝트는 **7 영역**으로 구성되며, 모든 phase·plan·decision은 *어느 영역에 속하는지* 표기한다. (원안 6영역 → 7영역으로 재정의: `00-contracts` 신설·VM 비대 분리·외부 통합 영역 재정의)

| # | 영역 | 위치 | 책임 |
|---|------|------|------|
| 00 | `contracts` | `areas/00-contracts/README.md` | manifest schema · region/slot/iteration 모델 · run_id · 결과 디렉토리 구조 · 용어집 (단일 진실) |
| 01 | `planning` | `areas/01-planning/README.md` | 매니페스트 작성 · scenario 설계 · 가설 절 |
| 02 | `orchestration` | `areas/02-orchestration/README.md` | run.sh · fire-and-forget · 마커 · **이미지 swap·stack restart(VM 변동)** |
| 03 | `analysis` | `areas/03-analysis/README.md` | parse · prom_query · summarize · post-run SUMMARY 해석 보강 |
| 04 | `gatling-integration` | `areas/04-gatling-integration/README.md` | gatling repo 계약+풀가이드. Tracking: gatling `main` 동적 확인 |
| 05 | `realticket-integration` | `areas/05-realticket-integration/README.md` | RealTicket repo 계약+풀가이드. Tracking: realticket `dev` 동적 확인 + m2 dic hand-off slot |
| 06 | `vm-environment` | `areas/06-vm-environment/README.md` | **고정 인프라만** (Swarm·Sentinel·Prom/Grafana·SSH/키). 변동은 02 책임 |
| root | (root README) | `areas/README.md` | 7 영역 메타 진입 가이드 (v1.0 ENTRY.md 계승) |

### 04 / 05 — 동적 Tracking 패턴

`areas/04-gatling-integration/README.md`·`areas/05-realticket-integration/README.md` **첫 줄에 Tracking 1줄** (고정 해시 없음 — 동적 확인):

```
> Tracking: gatling repo `main` — 동적 확인: `git -C <gatling-repo> log origin/main -1 --format="%h %ad %s" --date=short`
> Tracking: realticket repo `dev` — 동적 확인: `git -C <realticket-repo> log origin/dev -1 --format="%h %ad %s" --date=short`
```

운영: 고정 해시 추적 없음. 최신 커밋 확인 시 위 git 명령을 직접 실행해 현재 HEAD를 동적으로 파악한다. drift 의심 시 같은 명령으로 현재 상태 확인. **자동 hook·script·티어드 워크플로우는 없음** (필요 시 m2+).

`areas/04-gatling-integration/README.md`·`areas/05-realticket-integration/README.md`는 본 repo가 의존하는 *인터페이스 표 + 풀가이드* (모듈 지도·변경 원칙·과거 함정 흡수).

**외부 repo 자체 README/CLAUDE.md는 수정 X** — bench는 *해석/원칙*만, 사실은 외부 진실. 두 진실 회피.

### 4 Lock 원칙 + 영역 매핑 (위배 절대 금지 — v1.0 ENTRY §3 계승)

| Lock | 원칙 | 책임 영역 |
|------|------|-----------|
| #1 | Claude 단일 제어 평면 — 매크로·SSHFS·Postman *전부 폐기* | **전 영역** |
| #2 | RealTicket BE 변경 0 — 기존 `POST /booking/init/:eventId` 재사용 | **05-realticket-integration** |
| #3 | 슬롯 alternating only — concurrent dual 미지원 | **02-orchestration** |
| #4 | Fire-and-forget + 자동 복귀 — VM `nohup`, RUNNING/COMPLETED/FAILED + progress.json | **02-orchestration** |

### AI 작업 방식 — 플랫폼 컨셉

본 플랫폼은 **AI가 단일 제어 평면**으로 벤치마크를 지휘한다. 사용자는 자연어 명령 한 번으로 전체 흐름이 완성된다.

**매니페스트 시작 트리거:** 사용자가 "매니페스트 시작하자" 또는 동등 자연어 → **반드시 [areas/01-planning/README.md § 매니페스트 수집 흐름 10단계](areas/01-planning/README.md) + § PlanConfig 확정 게이트 + § 목적 기반 해석 준비 + § AI 자동 derive 항목 + § 실행 전 재개 상태 운영** 을 먼저 읽고 그 순서대로 수집 → 자동 생성. schema 단일 진실은 [areas/00-contracts/README.md § Manifest Schema](areas/00-contracts/README.md) (15 core fields + optional bench_stack/context/implementation_plan/workflow_state).

**AI가 자동 수행하는 것 (사람 개입 0):**
1. 매니페스트 YAML 생성 (`bench/manifests/<id>.yaml`)
   - 실행 전 구현/브랜치 작업 중에는 매니페스트 `workflow_state` 를 갱신하여 새 세션 재개 포인터 유지
2. docker stack 정의 생성 (`bench-stack/<id>.yml`) — 4 기능 토글 활성 조합 yq merge
3. gatling repo 브랜치 분기·코드 수정·commit·push (`bench/<id>`)
4. RealTicket repo 브랜치 분기·yml commit·push (메타·슬롯 브랜치)
5. VM SSH → 브랜치 pull → docker build → docker stack deploy
6. 부하 시뮬레이션 실행 (`./gradlew gatlingRunAndArchive -P...`)
7. Prometheus 메트릭 수집
8. 분석 모듈 실행 → `SUMMARY.md` 자동 생성
9. 매니페스트 종료 → 외부 repo main 복귀 + 브랜치 영구 보존

**사용자가 하는 것:** 자연어 명령 + 결과 확인

**벤치 완료 후 해석 보강:** `run.sh` 는 fire-and-forget 종료 시 AI 해석을 호출하지 않는다. 사용자가 완료 후 자연어로 요청하면 AI가 매니페스트 `context` 와 `SUMMARY.md` 를 읽고 `areas/03-analysis/analyze/interpret_summary.py` 로 `SUMMARY.md` 의 관리 섹션을 추가/교체한다.

**영역별 작업 분담은 `areas/README.md` § AI 작업 지침 참조.**

### Heritage 진실 원천 (영역 CONTEXT.md 작성 시 인용)

- v1.0 audit (6 영역 매핑 출처): `..\naver-boostcamp-membership\GroupProject\web04-RealTicket\.planning\workstreams\bench-automation\v1.0-MILESTONE-AUDIT.md`
- INTENT/ENTRY/REQUIREMENTS/DECISION-INDEX: 동 디렉토리 루트
- phase별 결정 lock: 동 디렉토리 `phases/01..06/*-CONTEXT.md`·`*-SUMMARY.md`

### 외부 의존 (변경 없음)

- **Gatling repo**: `C:\Users\kxu45\ProgramStudy\gatling-practice\realticket-gatling-simulations` — 호출만, 수정은 별도 git
- **RealTicket repo**: `C:\Users\kxu45\ProgramStudy\naver-boostcamp-membership\GroupProject\web04-RealTicket` — ADM endpoint 호출만, BE 변경 0
- **VM**: `192.168.138.2` (`ssh VM_ubuntu`) — Docker Swarm + Prometheus(9090) + Grafana(3000)

### 현재 milestone

**m1 완료 (2026-05-05)**: 7 영역 컨텍스트 문서 완비·bench/ 재구성·자체 dry-run 단대단 입증 완료. 외부 dic 호출 인터페이스는 m2 이후. `.planning/ROADMAP.md` 참조.

---

## Project

**realticket-bench-platform**

Claude Code(Bash)가 단일 제어 평면으로 RealTicket(또는 동형 백엔드)의 부하 벤치마크를 *지휘*하는 독립 플랫폼이다. 사용자는 자연어 명령("매니페스트 X 6시간 돌려") 하나로 시뮬레이션 실행·세션 초기화·메트릭 수집·결과 요약·가설 판정까지 끝내고, 완료 후 별도 자연어 요청으로 목적 기반 해석을 `SUMMARY.md` 에 보강할 수 있다.

본 repo는 **벤치마크 *지휘자* 역할의 신규 상위 레포**이며, 외부 도구(Gatling 시뮬레이션 프로젝트·VM 스택)는 본 repo가 *호출*만 한다 — 도구 코드 자체는 외부에 둔다.

> **Heritage:** 본 프로젝트는 RealTicket의 `bench-automation` 워크스트림 v1.0(28/28 REQ + 5 Lock 원칙 + 6 phase, 2026-05-02 PASSED)이 졸업한 결과물이다. 검증된 *지식*과 *설계 결정*은 흡수하지만, *코드 구조는 재구성* — 복사 아님, 처음부터 새로 쌓아올림. git history도 신규 시작.

**Core Value:** **"Claude 명령 한 번 → 신뢰성 있는 벤치마크 측정"**

이 한 가지가 무너지면 다른 모든 것이 의미 없다. 정확한 숫자보다 *재현성·자동화·단일 제어 평면*이 우선. 사용자가 매크로/SSHFS/Postman으로 돌아가야 한다면 본 프로젝트는 실패다.

### Constraints

- **Tech stack**: Bash + Python(분석) + YAML(매니페스트). 새 언어·프레임워크 도입 금지 — Lock #1 단일 제어 평면 정신 보존
- **외부 의존**: gatling repo는 별도 git 저장소로 *유지* (모노레포화 금지). RealTicket repo는 *호출 대상*으로만 취급, BE 코드 변경 0
- **타깃 환경**: VM(192.168.138.2) Docker Swarm. AWS 자동화는 별도 워크스트림(별 milestone)
- **모니터링**: 기존 Prometheus/Grafana/cAdvisor 그대로. 새 스택 도입 금지
- **반복성**: alternating only. concurrent dual 부하 미지원
- **장기 실행**: 6시간 단위 fire-and-forget 가능해야 함 — 사용자 conversation 유지 불요·Claude 토큰 0
- **재현성**: 매니페스트 = 1세트 단일 진실. 매니페스트만 보면 무엇이 어떻게 측정되는지 100% 결정됨

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- the small-fix GSD entry point for focused fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.

## Commit Message Convention

- Subject는 conventional prefix(`feat`, `fix`, `docs`, `chore` 등)를 사용하고, 필요하면 scope를 붙인다.
- Subject 본문은 기존 히스토리처럼 영어와 한국어를 자연스럽게 섞어도 된다. 억지로 영어만 쓰지 않는다.
- Body는 "무엇을 구현했는가"보다 "어떤 목적인가", "왜 이렇게 했는가"를 중심으로 쓴다.
- Subject만으로 목적이 충분히 명확하면 body를 생략한다.
- Body가 두 줄 이상이면 bullet 형식으로 작성한다.
- Trailer(`Co-Authored-By` 등)는 bullet로 만들지 않고 마지막에 별도 유지한다.

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
