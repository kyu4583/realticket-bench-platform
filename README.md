# realticket-bench-platform

**AI를 실행 주체로 설계한 부하 벤치마크 플랫폼이다.** 사용자의 역할은 자연어 명령과 결과 확인이 전부다.

사용자가 벤치마크를 시작하면 AI는 측정 목적·슬롯 구성·기능 토글·region 분할을 순서대로 물어 매니페스트를 완성한다. 이후 7개 영역 전체에 걸쳐 준비와 실행을 직접 계획하고 진행한다 — Gatling 시나리오 코드 수정, RealTicket 스택 정의, 외부 repo 브랜치 관리, VM 빌드·배포까지.

변경이 매니페스트마다 달라지는 만큼, 각 영역은 브랜치 전략·격리 규칙·인터페이스 계약을 컨텍스트 문서로 명문화한다. 이 문서들이 AI에게 충분한 맥락을 제공하고 계약 범위를 벗어난 수정을 방지하는 가이드레일 역할을 한다.

## 왜 필요한가?

벤치마크 목적이 바뀔 때마다 함께 바뀌어야 하는 요소가 많아 번거롭다.

- **Gatling 시나리오** — 사소한 서버 API 명세 변경 대응이나 가상 사용자의 행동 변경 등, 깊이는 얕지만 번거로운 수정이 잦다. 해당 벤치마크에서만 쓰이는 일회성 변경인 경우도 많아 브랜치 격리와 버전 관리까지 신경써야 한다.
- **docker stack 구성** — Nest 슬롯 수, Redis Sentinel 활성화, 오토스케일링, 테스트 계정 사전 적재 등 조합이 목적마다 달라진다.
- **이미지 빌드·VM 배포** — 스택 구성이 확정되면 RealTicket 소스를 VM으로 전달하고 Docker 이미지를 빌드한 뒤 stack을 재기동해야 한다. SSH 접속·소스 전달·이미지 빌드·스택 재기동이 매 벤치마크마다 반복되는 수작업이다.
- **측정·분석 범위** — 어떤 구간에 집중하는지, 구간을 어떻게 자르는지, Prometheus에서 무엇을 수집하는지, 결과를 어떤 기준으로 해석하는지가 시나리오와 함께 달라진다.


매번 이 요소들을 수동으로 맞추는 대신, "이런 목적으로 벤치마크를 하고 싶다"는 자연어 명령 하나로 전부 구성하고 실행하는 플랫폼이 필요했다.

단, AI에게 명령만 내리는 것으로는 원하는 결과를 얻기 어렵다. 숙지할 내용이 많고 지켜야 할 규칙이 세밀하며 목적마다 달라지는 변수도 많다 — 맥락 없이 시키면 빠뜨리거나 일관성을 잃기 쉽다. 그래서 책임을 7개 영역으로 나누고 각 영역에 컨텍스트 문서를 명세한다. AI가 각 영역에서 무엇을 어떻게 해야 하는지, 무엇을 하면 안 되는지를 정확히 알고 일관되게 행동하기 위해서다.

## 플랫폼 컨셉

**사용자가 하는 것:** 자연어 명령 + 결과 확인

**AI가 자동으로 수행하는 것:**

1. 매니페스트 수집 — 사용자에게 7단계 질문으로 벤치마크 설계 완성
2. docker stack 정의 생성 — 4 기능 토글 조합에 따라 자동 합성
3. Gatling repo 브랜치 분기·코드 수정·commit·push
4. RealTicket repo 브랜치 분기·yml commit·push
5. VM SSH → 이미지 빌드 → docker stack deploy
6. 부하 시뮬레이션 실행 (Gatling)
7. Prometheus 메트릭 수집
8. 분석 모듈 실행 → `SUMMARY.md` 자동 생성
9. 외부 repo main 복귀 + 브랜치 영구 보존

## 시작하기

### 일반 사용자 경로

**1단계 — 환경 설정 (최초 1회)**

```bash
cp areas/06-vm-environment/.env.example areas/06-vm-environment/.env
# areas/06-vm-environment/.env 에 GATLING_DIR, REALTICKET_DIR, VM_HOST, ADMIN_ID, ADMIN_PASSWORD 입력
```

**2단계 — AI에게 자연어로 요청**

```
"매니페스트 시작하자"
```

AI가 측정 목적·슬롯 구성·기능 토글·region 분할 등을 순서대로 질문하고, 답변을 바탕으로 매니페스트 작성·외부 repo 브랜치 분기·VM 빌드·시뮬레이션 실행·결과 분석까지 자동으로 완료한다.

일반 사용자가 `bash` 명령을 직접 실행할 필요는 없다.

### 개발자 검증 경로

이미 작성된 매니페스트를 수동 검증할 때만 단일 진입점을 직접 실행한다.

```bash
bash areas/02-orchestration/run.sh bench/manifests/<manifest>.yaml
```

## 7영역 구조

본 플랫폼은 7개 영역으로 관심사를 분리한다. 각 영역은 AI가 벤치마크를 지휘할 때 개입하는 독립적인 책임 범위를 정의한다.

| # | 영역 | 책임 |
|---|------|------|
| 00 | [contracts](areas/00-contracts/README.md) | manifest schema 16 core fields + optional `bench_stack` · 결과 디렉토리 구조 · 용어집 |
| 01 | [planning](areas/01-planning/README.md) | 매니페스트 수집 흐름 · scenario 설계 |
| 02 | [orchestration](areas/02-orchestration/README.md) | run.sh · 브랜치 라이프사이클 · fire-and-forget |
| 03 | [analysis](areas/03-analysis/README.md) | 분석 모듈 · 결과 해석 |
| 04 | [gatling-integration](areas/04-gatling-integration/README.md) | Gatling repo 인터페이스 · 브랜치 격리 |
| 05 | [realticket-integration](areas/05-realticket-integration/README.md) | RealTicket repo 인터페이스 · VM 빌드 |
| 06 | [vm-environment](areas/06-vm-environment/README.md) | VM 고정 인프라 · 헬스체크 |

→ [영역 전체 가이드 및 AI 작업 분담](areas/README.md)

## 5 Lock 원칙

| Lock | 원칙 |
|------|------|
| #1 | AI 단일 제어 평면 — 매크로·SSHFS·Postman 없이 AI가 모든 것을 제어 |
| #2 | RealTicket BE 변경 0 — 기존 `POST /booking/init/:eventId` 재사용 |
| #3 | 슬롯 alternating only — concurrent dual 미지원 |
| #4 | region이 단일 진실 — PlanGenerator의 `regions:`가 시뮬레이션·분석의 단일 출처 |
| #5 | Fire-and-forget + 자동 복귀 — VM `nohup`, RUNNING/COMPLETED/FAILED 마커 |

## 구조

```
bench/                         # 매니페스트와 결과 보관소
areas/                         # 7영역 문서 + 실행/분석 구현
areas/02-orchestration/run.sh  # 수동 검증용 단일 실행 진입점
AGENTS.md / CLAUDE.md          # AI 세션 진입 안내
```
