# 05-realticket-integration — RealTicket repo 계약 · 브랜치 격리

> Tracking: realticket repo `dev` — 동적 확인: `git -C <realticket-repo> log origin/dev -1 --format="%h %ad %s" --date=short`

본 영역은 RealTicket repo와 본 repo 사이의 계약·풀가이드를 lock한다. BE 코드 변경 0 (Lock #2). 외부 RealTicket repo 자체 README/CLAUDE.md는 수정하지 않는다 — bench는 해석/원칙만.

---

## RealTicket repo 경로

```
C:\Users\kxu45\ProgramStudy\naver-boostcamp-membership\GroupProject\web04-RealTicket
```

- branch: `dev` (동적 확인)
- drift 점검: `git -C <repo> log origin/dev -1 --format="%h %ad %s" --date=short`

---

## BE Endpoint 시그니처

### POST /booking/init/:eventId

| 항목 | 값 |
|------|----|
| Method | `POST` |
| Path | `/booking/init/:eventId` |
| Path param | `eventId: number` |
| Request body | (없음) |
| Request headers | `Cookie: SID=<ADMIN_SESSION_SID>` (필수) |
| Guard | `@UseGuards(SessionAuthGuard(USER_STATUS.ADMIN))` |
| Response (정상) | `200 OK` 또는 `201` + `SuccessResponseDto { data: null }` |
| Response (인증 실패) | `401` 또는 `403` |
| Lock #2 재사용 명시 | dev 브랜치 영구 BE 변경 0건. 본 표가 변하면 외부 repo가 변한 것 |
| 멱등성 | SETNX 게이트로 멱등 보장 — 다중 호출 시 단일 초기화 |

**Admin 인증 흐름 (curl 한 줄, Lock #1):**

```bash
curl -X POST 'http://192.168.138.2:8080/booking/init/<eventId>' \
  -H 'Cookie: SID=<ADMIN_SESSION_SID>' \
  -i
# → 200 OK 또는 201 + SuccessResponseDto { data: null }
```

---

## prepare_realticket_branches() 수행 순서

매니페스트 시작 시 AI가 자동 수행하는 7단계:

1. RealTicket repo dev 브랜치 최신 상태 확인 (`git fetch origin`)
2. `bench/<manifest_id>/meta` 메타 브랜치 분기 (슬롯 수 무관, 항상 생성)
3. 슬롯 ≥ 2이면 `bench/<manifest_id>/<slot_name>` 슬롯 브랜치 추가 분기
4. 매니페스트 의도에 맞는 코드 변경 적용 (각 슬롯 브랜치별)
5. `bench-stack/<manifest_id>.yml` 작성 (generate_bench_stack_yml 결과를 메타 브랜치에 commit, `--no-verify` 필수)
6. 슬롯 브랜치에 동일 yml cherry-pick (`--no-verify` 필수)
7. 모든 브랜치 origin push (재실행 시 기존 브랜치를 `bench/<id>-before-<TS>`로 보존 후 force push)

---

## build_vm_images() VM 빌드 3단계

단계 (1)·(2)는 **슬롯별로 반복** 수행. 단계 (3)은 슬롯 수 무관 1회.

```bash
# (1) VM에서 원격 fetch
ssh VM_ubuntu "cd ~/web04-RealTicket && git fetch origin"

# (2) checkout 및 nest 이미지 빌드 — 슬롯별 반복
# 슬롯 1개:
ssh VM_ubuntu "cd ~/web04-RealTicket && git checkout -B 'bench/<manifest_id>' 'origin/bench/<manifest_id>' && docker build -f back/Dockerfile.dev-in-local -t 'nest:<manifest_id>' back/"
# 슬롯 N개 (각 슬롯마다):
ssh VM_ubuntu "cd ~/web04-RealTicket && git checkout -B 'bench/<manifest_id>/<slot_name>' 'origin/bench/<manifest_id>/<slot_name>' && docker build -f back/Dockerfile.dev-in-local -t 'nest:<manifest_id>-<slot_name>' back/"

# (3) bench-stack/<manifest_id>.yml 로 stack deploy — 슬롯 수 무관 1회
ssh VM_ubuntu "cd ~/web04-RealTicket && git fetch origin && git checkout 'origin/bench/<manifest_id>/meta' -- 'bench-stack/<manifest_id>.yml' && docker stack deploy -c 'bench-stack/<manifest_id>.yml' realticket"```
```

---

## 브랜치 전략

| 브랜치 | 목적 |
|--------|------|
| `bench/<manifest_id>/meta` | 메타 브랜치 — yml + 슬롯 무관 공통 코드. 항상 1개 |
| `bench/<manifest_id>/<slot_name>` | 슬롯 브랜치 — 슬롯별 코드 분기 + 동일 yml 복사. 슬롯 ≥ 2 시 N개 |

**불변 조건:**
- 변경 없는 매니페스트도 메타 브랜치 반드시 생성 (재현성)
- 브랜치 영구 보존 — 삭제 금지
- `bench/<manifest_id>` 루트 브랜치는 사용 금지. Git ref는 경로형 네임스페이스라 `refs/heads/bench/<manifest_id>`와 `refs/heads/bench/<manifest_id>/<slot_name>`이 동시에 존재할 수 없다. 과거 루트 브랜치가 있으면 `/meta`로 rename하거나 제거한 뒤 슬롯 브랜치를 만든다.

---

## bench-stack yml 컨벤션

RealTicket repo의 신규 폴더 `bench-stack/`은 본 repo가 책임지는 영역이다.

| 항목 | 값 |
|------|----|
| 위치 | `<RealTicket-repo-root>/bench-stack/<manifest_id>.yml` |
| commit 위치 | 메타 브랜치 + 슬롯 브랜치 모두에 동일 hash로 commit |
| 기본형 템플릿 출처 | `areas/02-orchestration/templates/docker-stack.base.yml` (본 repo) |
| 변형 가이드 마커 | `# CHANGE-α-login` / `# CHANGE-β-slots` / `# CHANGE-γ-scaling` |
| dev 브랜치 흔적 | 0건 — 매니페스트 ID 브랜치에만 존재 |

---

## 불변 조건

- RealTicket dev/main 브랜치 직접 변경 금지 (Lock #2 — 매니페스트 ID 브랜치에만 commit)
- `--no-verify` 없이 RealTicket repo에 commit 시도 금지 (husky pre-commit 거부)
- `|| true` silent-mask 금지 — commit 실패는 `die` fail-fast
- bench-stack yml commit은 bench_stack.sh 책임, branch.sh에는 commit 명령 0건

---

## 설계 smell 신호 (감지 시 즉시 중단)

아래 패턴 중 하나라도 발생하면 즉시 중단 후 사용자에게 보고:

1. main/dev 직접 변경 시도
2. `bench/<manifest_id>/meta` 또는 `bench/<manifest_id>/<slot_name>` 브랜치 삭제 시도. 단, 과거 잘못 생성된 루트 `bench/<manifest_id>` ref를 `/meta`로 rename/제거하는 1회 마이그레이션은 예외
3. 매니페스트 종료 후 외부 repo가 main이 아닌 상태
4. 슬롯 N개 매니페스트의 슬롯 브랜치 yml hash 불일치

---

## 과거 함정

- **TypeORM 커넥션 풀 고갈** — 부하 시 MySQL 풀 고갈 → timeout. `per_run` ≤ 운영 검증 임계 + reset 후 cooldown ≥ 15s
- **MySQL ECONNRESET** — 장시간 idle 후 첫 요청에 발생. `warmup` ≥ 30s + 첫 iteration 결과는 baseline에서 분리 검토
- **endpoint 명명 모호성** — `POST /booking/init/:eventId`는 최초 오픈과 재오픈 둘 다 해석 가능. VM(192.168.138.2) 한정 호출, AWS Production 호출 절대 금지
- **대기 큐 누수** — 비정상 종료 시 Redis 대기 큐 키 미정리 가능. `max_failures` 도달 FAILED 시 수동 reset 요구

---

## Tracking bump 시점

RealTicket dev에 변경이 생긴 경우 아래 명령으로 최신 커밋을 동적 확인한다: `git -C <repo> log origin/dev -1 --format="%h %ad %s" --date=short`

변경 영향:
- **BE Endpoint 시그니처 변경** → 본 파일 § BE Endpoint 시그니처 표 갱신 + `areas/02-orchestration/lib/lifecycle.sh` `reset_slots` 재검토
- **Docker 이미지 태그 컨벤션 변경** → 본 파일 갱신 + `areas/04-gatling-integration/lib/gatling.sh` stack restart 절차 재검토
- **VM 동기화 브랜치 변경** → 본 파일 갱신 + `areas/06-vm-environment/README.md` cross-check

---

## AI 작업 지침

### 수행하는 행동

- 매니페스트 시작 시: `prepare_realticket_branches()` 7단계 실행
- VM 빌드: `build_vm_images()` 3단계 ssh 트리거
- 매니페스트 종료 시: `restore_main_branches()` (main 복귀, 브랜치 삭제 X)

### 행동 금지

- dev/main 브랜치 직접 변경 금지
- 외부 repo README/CLAUDE.md 수정 금지
- `|| true` silent-mask 금지
- AWS Production endpoint 호출 절대 금지
