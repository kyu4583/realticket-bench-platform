# realticket-bench-platform

```
> "매니페스트 시작하자"
...

> "run해. 난 자고 올게"
```

**AI를 실행 주체로 설계한 부하 벤치마크 플랫폼이다.**

사용자는 자연어로 벤치마크 목적을 말하고 결과를 확인한다.

AI는 마련된 컨텍스트 문서와 Skill을 바탕으로 manifest 작성, Gatling/RealTicket 준비, VM 배포, 실행, 분석, `SUMMARY.md` 생성까지 지휘한다.


## 관련 repo

| repo | 역할 |
|---|---|
| [web04-RealTicket](https://github.com/boostcampwm-2024/web04-RealTicket) | 측정 대상 서비스 |
| [realticket-gatling-simulations](https://github.com/kyu4583/realticket-gatling-simulations) | Gatling 부하 시뮬레이터 |
| `realticket-bench-platform` | 벤치마크 지휘 repo |

이 repo는 RealTicket이나 Gatling 코드를 포함하지 않는다. manifest와 run pipeline을 통해 외부 repo를 호출하고, 브랜치·VM·분석 산출물을 조율한다.

## 핵심 흐름

1. 사용자가 자연어로 벤치마크 목적을 설명한다.
2. AI가 측정 목적·슬롯 구성·기능 토글·region 분할을 물어 manifest를 완성한다.
3. AI가 Gatling 시나리오, RealTicket stack 정의, 외부 repo 브랜치, VM 빌드·배포를 준비한다.
4. `run.sh`가 fire-and-forget 방식으로 Gatling 실행과 Prometheus 수집을 진행한다.
5. 분석 모듈이 `SUMMARY.md`를 생성한다.
6. 완료 후 사용자가 요청하면 AI가 목적 기반 해석 섹션을 추가하거나 교체한다.

## 왜 필요한가?

벤치마크 목적이 바뀔 때마다 함께 바뀌어야 하는 요소가 많아 번거롭다.

- **Gatling 부하 시뮬레이션 시나리오** — 사소한 서버 API 명세 변경 대응이나 가상 사용자의 행동 변경 등, 깊이는 얕지만 번거로운 수정이 잦다. 해당 벤치마크에서만 쓰이는 일회성 변경인 경우도 많아 브랜치 격리와 버전 관리까지 신경써야 한다.
- **docker stack 구성** — Nest 슬롯 수, Redis Sentinel 활성화, 오토스케일링, 테스트 계정 사전 적재 등 조합이 목적마다 달라진다.
- **이미지 빌드·VM 배포** — 스택 구성이 확정되면 RealTicket 소스를 VM으로 전달하고 Docker 이미지를 빌드한 뒤 stack을 재기동해야 한다. SSH 접속·소스 전달·이미지 빌드·스택 재기동이 매 벤치마크마다 반복되는 수작업이다.
- **측정·분석 범위** — 어떤 구간에 집중하는지, 구간을 어떻게 자르는지, Prometheus에서 무엇을 수집하는지, 결과를 어떤 기준으로 해석하는지가 시나리오와 함께 달라진다.

매번 이 요소들을 수동으로 맞추는 대신, "이런 목적으로 벤치마크를 하고 싶다"는 자연어 명령 하나로 전부 구성하고 실행하는 플랫폼이 필요했다.

단, AI에게 명령만 내리는 것으로는 원하는 결과를 얻기 어렵다. 숙지할 내용이 많고 지켜야 할 규칙이 세밀하며 목적마다 달라지는 변수도 많다 — 맥락 없이 시키면 빠뜨리거나 일관성을 잃기 쉽다.

그래서 책임을 7개 영역으로 나누고, 영역별 판단 기준은 컨텍스트 문서에, 반복 운영 절차는 Skill에 고정했다. AI가 각 영역에서 해야 할 일과 하지 말아야 할 일을 일관되게 판단하도록 하기 위해서다.

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


## 핵심 파이프라인

이 플랫폼은 manifest를 기준으로 외부 repo, stack 정의, VM 실행 환경, 결과 산출물을 한 흐름으로 묶는다.

```
사용자 자연어 요청
  -> 매니페스트 확정: bench/manifests/<manifest_id>.yaml
  -> 외부 repo 브랜치 준비
       ├─ Gatling: 시나리오 리서치 -> 구현 -> 커밋
       └─ RealTicket: meta/slot 브랜치 -> stack/runtime 입력 고정
  -> Docker stack 정의: bench-stack/<manifest_id>.yml
  -> VM 배포: 이미지 빌드 + docker stack deploy
  -> 부하 실행: Gatling run + Prometheus metric 수집
  -> 결과 산출: bench/results/<manifest_id>/<run_id>/
       ├─ manifest.yaml                 # 실행 시점 manifest snapshot
       ├─ progress.json                  # 진행 상태
       ├─ RUNNING / COMPLETED / FAILED   # 실행 marker
       ├─ iter-N-<slot>/                 # iteration별 원천 데이터
       └─ SUMMARY.md                     # 최종 요약
```

| 단계 | 무엇을 고정하는가 | 산출물 |
|---|---|---|
| Manifest | 비교 목적, 슬롯, 기능 토글, region, query, 실행 계획 | `bench/manifests/<manifest_id>.yaml` |
| Gatling 리서치 | 기존 시나리오 구조, 재사용 범위, 필요한 변경점 | `implementation_plan.gatling` |
| Gatling 구현 | manifest 전용 시나리오 변경 | Gatling repo `bench/<manifest_id>` 브랜치 |
| RealTicket 준비 | 측정 대상 branch와 slot별 실행 기준 | RealTicket repo `bench/<manifest_id>/*` 브랜치 |
| Stack 생성 | 슬롯 수, 테스트 계정, Sentinel, autoscaler 등 실행 조건 | `bench-stack/<manifest_id>.yml` |
| VM 배포 | 이미지 빌드, stack deploy, 서비스 health | VM Docker Swarm stack |
| 실행·분석 | iteration 진행, Gatling 결과, Prometheus metric, 요약 | `bench/results/<manifest_id>/<run_id>/SUMMARY.md` |

외부 repo 변경은 manifest별 `bench/<manifest_id>` 계열 브랜치에 격리한다. 벤치가 끝나면 각 repo는 기준 브랜치로 되돌리고, 벤치 브랜치는 재현성과 사후 검토를 위해 보존한다.

## 빠른 시작

Codex에서는 `$realticket-bench-operator`, Claude Code에서는 project skill `realticket-bench-operator`가 운영 entrypoint다. Skill은 반복 운영 절차를 제공하고, schema·Lock·외부 repo 계약의 단일 진실은 `areas/*/README.md`다.

### 1단계 — AI skill 준비

**Claude Code**

추가 설치가 필요 없다. 최신 변경을 pull한 뒤 **repo root에서 새 Claude Code 세션**을 시작하면, Claude Code가 `.claude/skills/realticket-bench-operator/` project skill을 자동 발견한다.

Claude Code 쪽 skill 본체는 `.claude/skills/realticket-bench-operator/SKILL.md`이며, 실제 운영 workflow는 공유 원본 `.agents/skills/realticket-bench-operator/SKILL.md`를 읽도록 위임한다.

**Codex**

Codex는 사용자별 skill 디렉토리를 사용하므로 최초 1회 등록이 필요하다. 등록 후 새 Codex 세션에서 `$realticket-bench-operator`를 사용한다.

<details>
<summary>Codex skill 등록 명령</summary>

**Windows PowerShell**

```powershell
$src = ".agents\skills\realticket-bench-operator"
$dst = "$env:USERPROFILE\.codex\skills\realticket-bench-operator"
New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Copy-Item -Recurse $src $dst
$env:PYTHONUTF8 = "1"
python "$env:USERPROFILE\.codex\skills\.system\skill-creator\scripts\quick_validate.py" $dst
```

**macOS / Linux shell**

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

</details>

### 2단계 — 환경 설정

```bash
cp areas/06-vm-environment/.env.example areas/06-vm-environment/.env
# areas/06-vm-environment/.env 에 GATLING_DIR, REALTICKET_DIR, VM_HOST, ADMIN_ID, ADMIN_PASSWORD 입력
```

### 3단계 — AI에게 자연어로 요청

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
