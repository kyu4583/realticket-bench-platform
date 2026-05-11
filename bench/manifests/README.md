# bench/manifests — 매니페스트 파일 보관소

## 책임 범위

실제 매니페스트 yaml 파일과 예시 파일을 보관한다. 매니페스트 = *1 벤치마크 세트의 모든 변수* 단일 진실 (재현성).

## 영역 spec 참조

schema 정의와 작성 가이드의 단일 진실은 영역 문서에 lock — 본 README 는 *link O · 재진술 X*.

- Manifest Schema (15 core fields + optional objects): [`areas/00-contracts/README.md`](../../areas/00-contracts/README.md) — core fields enumeration · 타입 · required · 의미 단일 진실
- 매니페스트 작성 가이드: [`areas/01-planning/README.md`](../../areas/01-planning/README.md) — scenario 설계 원칙 + α/β/γ/δ 질문 흐름 + PlanConfig 확정 게이트
- `slots[].scenario_mode` override + PlanConfig 계약: [`areas/04-gatling-integration/README.md`](../../areas/04-gatling-integration/README.md) — `Config.java` default `LOGIN_ONLY`, `PlanConfig.json` 입력, PlanGenerator 실행 전 확인 게이트

> **Example quarantine:** `_example-*.yaml` 의 커스텀 `scenario_mode` 값은 schema 시연용 placeholder다. 신규 매니페스트 작성 시 복사하지 않는다. 실제 `slots[].scenario_mode` 값은 사용자가 명시 입력하거나 AI 제안을 사용자가 확인한 경우에만 기록한다. 미확정이면 필드를 생략하고 `implementation_plan.gatling.scenario_decisions` 에 pending 결정으로 남긴다.

## 디렉토리 구조

```
manifests/
├── README.md             # 본 파일
├── _example-min.yaml     # 1 슬롯·1 region·iter:1·hypotheses 없음
└── _example-full.yaml    # 2 슬롯·hypotheses 포함·scenario_mode override
```

schema의 기계 가독 placeholder는 `areas/00-contracts/schema.yaml`에 둔다.

> `_example-*.yaml` 의 `_` prefix 는 예시와 실제 매니페스트 (예: `m1-self-dry-run.yaml`) 를 명명으로 구분.

## 작성 흐름

1. `areas/01-planning/README.md § 매니페스트 수집 흐름 10단계` 의 순서대로 사용자에게 질문 (AI 가 진행)
2. `manifest_id` 는 사용자에게 명시 입력으로 받고, 비교 변수와 별도 turn 으로 확정
3. α/β/γ/δ 차원 질문 → bench-stack yml 변형 결정
4. PlanGenerator 실행 전에 `PlanConfig.json` 설정값을 확정하고, 확정값·derive값·미확정값을 `context.plan_config` 에 기록
5. `bench/manifests/<manifest_id>.yaml` 생성 (15 core fields + optional `bench_stack`·`context`·`implementation_plan`·`workflow_state`). `context` 에는 post-run 해석을 위해 `purpose`·`comparison_axis`·`decision_question`·`interpretation_focus`·`controls` 를 함께 기록
6. 구현 세션마다 `workflow_state` 의 `current_task_ref`·`last_completed`·`next_action` 갱신
7. `workflow_state.status: ready_to_run` 이 되면 `bash areas/02-orchestration/run.sh bench/manifests/<manifest_id>.yaml` 실행

`workflow_state` 는 실행 전 재개 포인터다. `run.sh` 실행 이후의 진행률은 매니페스트가 아니라 `bench/results/<manifest_id>/<run_id>/progress.json` 과 마커 파일을 확인한다.

## post-run SUMMARY 해석

`run.sh` 는 AI 해석을 자동 호출하지 않는다. 벤치가 `COMPLETED` 된 뒤 사용자가 자연어로 요청하면 AI가 매니페스트 `context` 와 `SUMMARY.md` 를 읽고 `areas/03-analysis/analyze/interpret_summary.py` 로 `SUMMARY.md` 안의 관리 섹션을 추가 또는 교체한다.

## Out of Scope

- schema validator 코드 → yq + Bash assert 로 충분
- 매니페스트 작성 자동화 도구 → AI 대화형 수집
- 가설 판정 로직 → `areas/03-analysis/analyze/summarize.py`
- run_id 형식 → `areas/00-contracts/README.md` § run_id 형식
