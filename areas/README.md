# 7영역 전체 가이드

본 플랫폼은 AI가 벤치마크를 지휘할 때 개입하는 책임 범위를 7개 영역으로 분리한다.
각 문서는 GSD 워딩 없이, 플랫폼 컨셉과 AI 작업 지침을 중심으로 작성되었다.

## 읽는 순서

처음 접하는 경우 아래 순서를 따른다:

1. **[00-contracts/README.md](./00-contracts/README.md)** — 전체 플랫폼의 공통 언어(manifest schema·region/slot/iteration 모델·결과 디렉토리 구조·용어집). 다른 영역을 읽기 전에 반드시 먼저 확인
2. **[01-planning/README.md](./01-planning/README.md)** — AI가 사용자로부터 매니페스트를 수집하는 10단계 흐름
3. **[02-orchestration/README.md](./02-orchestration/README.md)** — run.sh 17 함수 + 브랜치 라이프사이클 + fire-and-forget
4. **[03-analysis/README.md](./03-analysis/README.md)** — 3 분석 모듈(parse·prom_query·summarize)과 결과 해석
5. **[04-gatling-integration/README.md](./04-gatling-integration/README.md)** — Gatling repo 인터페이스 · -P 키 · 브랜치 격리
6. **[05-realticket-integration/README.md](./05-realticket-integration/README.md)** — RealTicket repo 인터페이스 · VM 빌드
7. **[06-vm-environment/README.md](./06-vm-environment/README.md)** — VM 고정 인프라 · 헬스체크

## 영역별 역할 표

| # | 영역 | 파일 | AI 개입 빈도 | 핵심 책임 |
|---|------|------|-------------|---------|
| 00 | contracts | [00-contracts/README.md](./00-contracts/README.md) | 읽기 전용 (정의 참조) | manifest schema 15 core fields + optional objects · region/slot/iteration 모델 · 결과 디렉토리 구조 · 용어집 |
| 01 | planning | [01-planning/README.md](./01-planning/README.md) | 매니페스트 시작 시 | 사용자 질문 수집 10단계 · PlanConfig 확정 게이트 · Gatling read-only 리서치 · 구현 계획 자동 생성 · 실행 전 재개 상태 |
| 02 | orchestration | [02-orchestration/README.md](./02-orchestration/README.md) | 매니페스트 실행 전·중·후 | run.sh 17 함수 · fire-and-forget · 브랜치 분기·복귀 |
| 03 | analysis | [03-analysis/README.md](./03-analysis/README.md) | 실행 완료 후 결과 확인 시 | parse·prom_query·summarize 3 모듈 · SUMMARY.md 생성 |
| 04 | gatling-integration | [04-gatling-integration/README.md](./04-gatling-integration/README.md) | 매니페스트별 브랜치 격리 | gatling repo 계약 · -P 키 표 · ScenarioMode 6개 |
| 05 | realticket-integration | [05-realticket-integration/README.md](./05-realticket-integration/README.md) | 매니페스트별 브랜치 격리 + VM 빌드 | RealTicket repo 계약 · VM 이미지 빌드 · bench-stack yml |
| 06 | vm-environment | [06-vm-environment/README.md](./06-vm-environment/README.md) | 실행 전 헬스체크 | Docker Swarm · Prometheus · Grafana · Sentinel · SSH |

## 영역 간 호출 순서

매니페스트 1개 실행의 전체 흐름에서 영역이 개입하는 순서:

```
01 (매니페스트 수집 완료)
  ↓
00 (브랜치 명명 규칙 참조)
  ↓
04 (gatling repo read-only 리서치 → implementation_plan.gatling 기록)
  ↓
01 (workflow_state 초기화 — 새 세션 재개 포인터)
  ↓
구현 세션 (gatling repo bench/<manifest_id> 브랜치 분기·수정·push)
  ↓
05 (RealTicket repo bench/<manifest_id> 브랜치 분기·yml commit·push)
  ↓
06 (VM 헬스체크 — Swarm/Prom/SSH 확인)
  ↓
05 (VM: git pull → docker build → docker stack deploy)
  ↓
02 (run.sh: admin_login → reset_slots → iter 루프)
  ↓
  ├── 04 (run_gatling: ./gradlew gatlingRunAndArchive -P...)
  ├── 02 (collect_prometheus: Prometheus query_range)
  └── 03 (parse·prom_query·summarize: 결과 생성)
  ↓
02 (restore_main_branches: gatling + RealTicket main 복귀)
  ↓
03 (SUMMARY.md 확인)
```

## AI 작업 지침

새 세션 진입 시 이 문서를 먼저 읽고 7영역 역할 표를 파악한 뒤, 작업 대상 영역의 개별 문서를 읽는다. "읽는 순서" 항목을 따라 00-contracts부터 순서대로 확인한다.

## AI 금지 사항 (전 영역 공통)

- 매크로·SSHFS·Postman 사용 금지 — 모든 조작은 Bash 한 줄 (Lock #1)
- RealTicket main/dev 브랜치 직접 변경 금지 — 매니페스트 ID 브랜치에만 commit (Lock #2)
- 두 슬롯 동시 부하 구현 금지 (Lock #3 영구 미지원)
- fire-and-forget을 foreground로 변경 금지 (Lock #4)
- 외부 gatling/RealTicket repo의 README·CLAUDE.md 수정 금지
- `.planning/` 문서 링크를 areas/ 문서에 포함 금지 (gitignored)
