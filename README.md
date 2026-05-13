**관련 repo:**
- 측정 대상 서비스 Real-Ticket: [web04-RealTicket](https://github.com/boostcampwm-2024/web04-RealTicket)
- Gatling 부하 시뮬레이터: [realticket-gatling-simulations](https://github.com/kyu4583/realticket-gatling-simulations)

# realticket-bench-platform

**AI를 실행 주체로 설계한 부하 벤치마크 플랫폼이다.** 사용자의 역할은 자연어 명령과 결과 확인이 전부다.

사용자가 벤치마크를 시작하면 AI는 측정 목적·슬롯 구성·기능 토글·region 분할을 순서대로 물어 매니페스트를 완성한다. 이후 7개 영역 전체에 걸쳐 준비와 실행을 직접 계획하고 진행한다 — Gatling 시나리오 코드 수정, RealTicket 스택 정의, 외부 repo 브랜치 관리, VM 빌드·배포까지.

변경이 매니페스트마다 달라지는 만큼, 각 영역은 브랜치 전략·격리 규칙·인터페이스 계약을 컨텍스트 문서로 명문화한다. 이 문서들이 AI에게 충분한 맥락을 제공하고 계약 범위를 벗어난 수정을 방지하는 가이드레일 역할을 한다.

## 왜 필요한가?

벤치마크 목적이 바뀔 때마다 함께 바뀌어야 하는 요소가 많아 번거롭다.

- **Gatling 부하 시뮬레이션 시나리오** — 사소한 서버 API 명세 변경 대응이나 가상 사용자의 행동 변경 등, 깊이는 얕지만 번거로운 수정이 잦다. 해당 벤치마크에서만 쓰이는 일회성 변경인 경우도 많아 브랜치 격리와 버전 관리까지 신경써야 한다.
- **docker stack 구성** — Nest 슬롯 수, Redis Sentinel 활성화, 오토스케일링, 테스트 계정 사전 적재 등 조합이 목적마다 달라진다.
- **이미지 빌드·VM 배포** — 스택 구성이 확정되면 RealTicket 소스를 VM으로 전달하고 Docker 이미지를 빌드한 뒤 stack을 재기동해야 한다. SSH 접속·소스 전달·이미지 빌드·스택 재기동이 매 벤치마크마다 반복되는 수작업이다.
- **측정·분석 범위** — 어떤 구간에 집중하는지, 구간을 어떻게 자르는지, Prometheus에서 무엇을 수집하는지, 결과를 어떤 기준으로 해석하는지가 시나리오와 함께 달라진다.


매번 이 요소들을 수동으로 맞추는 대신, "이런 목적으로 벤치마크를 하고 싶다"는 자연어 명령 하나로 전부 구성하고 실행하는 플랫폼이 필요했다.

단, AI에게 명령만 내리는 것으로는 원하는 결과를 얻기 어렵다. 숙지할 내용이 많고 지켜야 할 규칙이 세밀하며 목적마다 달라지는 변수도 많다 — 맥락 없이 시키면 빠뜨리거나 일관성을 잃기 쉽다. 그래서 책임을 7개 영역으로 나누고 각 영역에 컨텍스트 문서를 명세한다. AI가 각 영역에서 무엇을 어떻게 해야 하는지, 무엇을 하면 안 되는지를 정확히 알고 일관되게 행동하기 위해서다.

## 플랫폼 컨셉

**사용자가 하는 것:** 자연어 명령 + 결과 확인

**AI 운영 entrypoint:** Codex는 `$realticket-bench-operator`, Claude Code는 project skill `realticket-bench-operator`가 절차 진입점이다. 이 repo는 공유 skill 원본을 `.agents/skills/realticket-bench-operator/`에 보관하고, Claude Code project skill은 `.claude/skills/realticket-bench-operator/`에서 그 원본을 참조한다. skill은 운영 workflow만 담고, schema·Lock·외부 repo 계약은 계속 `areas/*/README.md`를 단일 진실로 참조한다.

**AI가 자동으로 수행하는 것:**

1. 매니페스트 수집 — 사용자에게 10단계 질문으로 벤치마크 설계 완성
2. Gatling 코드베이스 read-only 리서치 → `implementation_plan.gatling` 기록 + `workflow_state` 재개 포인터 초기화
3. 구현 세션에서 docker stack 정의·Gatling 코드·RealTicket 브랜치 준비
4. VM SSH → 이미지 빌드 → docker stack deploy
5. 부하 시뮬레이션 실행 (Gatling)
6. Prometheus 메트릭 수집
7. 분석 모듈 실행 → `SUMMARY.md` 자동 생성
8. 외부 repo main 복귀 + 브랜치 영구 보존
9. 사용자가 완료 후 자연어로 요청하면 AI가 매니페스트 목적에 따른 `SUMMARY.md` 해석 섹션 추가/교체

## 시작하기

### 0단계 — AI skill 사용 준비

#### Claude Code

추가 설치가 필요 없다. 최신 변경을 pull한 뒤 **repo root에서 새 Claude Code 세션**을 시작하면, Claude Code가 `.claude/skills/realticket-bench-operator/` project skill을 자동 발견한다.

Claude Code 쪽 skill 본체는 `.claude/skills/realticket-bench-operator/SKILL.md`이며, 실제 운영 workflow는 공유 원본 `.agents/skills/realticket-bench-operator/SKILL.md`를 읽도록 위임한다.

#### Codex

Codex는 사용자별 skill 디렉토리를 사용하므로 최초 1회 등록이 필요하다. **repo root**에서 현재 OS에 맞는 명령을 실행한다.

Windows PowerShell:

```powershell
$src = ".agents\skills\realticket-bench-operator"
$dst = "$env:USERPROFILE\.codex\skills\realticket-bench-operator"
New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Copy-Item -Recurse $src $dst
$env:PYTHONUTF8 = "1"
python "$env:USERPROFILE\.codex\skills\.system\skill-creator\scripts\quick_validate.py" $dst
```

macOS / Linux shell:

```bash
src=".agents/skills/realticket-bench-operator"
dst="${CODEX_HOME:-$HOME/.codex}/skills/realticket-bench-operator"
mkdir -p "$(dirname "$dst")"
rm -rf "$dst"
cp -R "$src" "$dst"
PYTHONUTF8=1 python "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py" "$dst"
```

검증 결과가 `Skill is valid!`이면 **새 Codex 세션**에서 `$realticket-bench-operator`를 사용할 수 있다.

검증 스크립트 경로가 없어 실패하더라도 `Copy-Item` 또는 `cp -R`까지 성공했다면 skill 복사는 완료된 상태다. 이 경우 새 Codex 세션에서 `$realticket-bench-operator`가 보이는지 확인한다.

### 1단계 — 환경 설정 (최초 1회)

```bash
cp areas/06-vm-environment/.env.example areas/06-vm-environment/.env
# areas/06-vm-environment/.env 에 GATLING_DIR, REALTICKET_DIR, VM_HOST, ADMIN_ID, ADMIN_PASSWORD 입력
```

### 2단계 — AI에게 자연어로 요청

```
"매니페스트 시작하자"
```

AI가 측정 목적·슬롯 구성·기능 토글·region 분할 등을 순서대로 질문하고, 답변을 바탕으로 매니페스트 작성·외부 repo 브랜치 분기·VM 빌드·시뮬레이션 실행·결과 분석까지 자동으로 완료한다.

일반 사용자가 `bash` 명령을 직접 실행할 필요는 없다.

### 완료 후 SUMMARY 해석 보강

벤치 실행은 fire-and-forget 방식이므로 `run.sh` 종료 시점에 AI 해석을 자동으로 붙이지 않는다. run 이 `COMPLETED` 된 뒤 사용자가 자연어로 요청하면 AI가 매니페스트 `context` 와 `SUMMARY.md` 를 읽고 목적 기반 해석을 추가한다.

```text
"sse-reconnect-vs-patch 최신 run SUMMARY에 목적 기준 해석 추가해줘"
```

내부 처리 순서:

```bash
python areas/03-analysis/analyze/interpret_summary.py bench/results/<manifest_id>/<run_id> --context
python areas/03-analysis/analyze/interpret_summary.py bench/results/<manifest_id>/<run_id> --file interpretation.md
```

`interpret_summary.py` 는 LLM을 호출하지 않고 `SUMMARY.md` 의 `<!-- AI_INTERPRETATION:START -->` / `<!-- AI_INTERPRETATION:END -->` 관리 섹션만 추가 또는 교체한다. 해석 본문은 사용자 요청을 받은 AI가 작성하며, 마지막에는 고정 템플릿이 아닌 사용자 선호 문체의 `### 정리` 문단으로 비교 기준과 핵심 수치 결론을 짧게 남긴다.

### 개발자 검증 경로

이미 작성된 매니페스트를 수동 검증할 때만 단일 진입점을 직접 실행한다.

```bash
bash areas/02-orchestration/run.sh bench/manifests/<manifest>.yaml
```

Windows PowerShell에서 `bash`가 직접 resolve되지 않으면 다음처럼 Git Bash shim을 통해 실행한다.

```powershell
sh -lc 'bash areas/02-orchestration/run.sh bench/manifests/<manifest>.yaml'
```

## 7영역 구조

본 플랫폼은 7개 영역으로 관심사를 분리한다. 각 영역은 AI가 벤치마크를 지휘할 때 개입하는 독립적인 책임 범위를 정의한다.

| # | 영역 | 책임 |
|---|------|------|
| 00 | [contracts](areas/00-contracts/README.md) | manifest schema 15 core fields + optional objects · 결과 디렉토리 구조 · 용어집 |
| 01 | [planning](areas/01-planning/README.md) | 매니페스트 수집 흐름 · scenario 설계 · Gatling 리서치 기반 구현 계획 · 실행 전 재개 상태 |
| 02 | [orchestration](areas/02-orchestration/README.md) | run.sh · 브랜치 라이프사이클 · fire-and-forget |
| 03 | [analysis](areas/03-analysis/README.md) | 분석 모듈 · post-run 결과 해석 보강 |
| 04 | [gatling-integration](areas/04-gatling-integration/README.md) | Gatling repo 인터페이스 · 브랜치 격리 |
| 05 | [realticket-integration](areas/05-realticket-integration/README.md) | RealTicket repo 인터페이스 · VM 빌드 |
| 06 | [vm-environment](areas/06-vm-environment/README.md) | VM 고정 인프라 · 헬스체크 |

→ [영역 전체 가이드 및 AI 작업 분담](areas/README.md)

## 4 Lock 원칙

| Lock | 원칙 |
|------|------|
| #1 | AI 단일 제어 평면 — 매크로·SSHFS·Postman 없이 AI가 모든 것을 제어 |
| #2 | RealTicket BE 변경 0 — 기존 `POST /booking/init/:eventId` 재사용 |
| #3 | 슬롯 alternating only — concurrent dual 미지원 |
| #4 | Fire-and-forget + 자동 복귀 — VM `nohup`, RUNNING/COMPLETED/FAILED 마커 |

## 구조

```
bench/                         # 매니페스트와 결과 보관소
areas/                         # 7영역 문서 + 실행/분석 구현
areas/02-orchestration/run.sh  # 수동 검증용 단일 실행 진입점
.agents/skills/                # Codex skill 배포 원본
.claude/skills/                # Claude Code project skill 진입점
AGENTS.md / CLAUDE.md          # AI 세션 진입 안내
```
