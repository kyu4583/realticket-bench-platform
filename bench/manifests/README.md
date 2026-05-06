# bench/manifests — 매니페스트 파일 보관소

## 책임 범위

실제 매니페스트 yaml 파일과 예시 파일을 보관한다. 매니페스트 = *1 벤치마크 세트의 모든 변수* 단일 진실 (재현성).

## 영역 spec 참조

schema 정의와 작성 가이드의 단일 진실은 영역 문서에 lock — 본 README 는 *link O · 재진술 X*.

- Manifest Schema (16 core fields + optional `bench_stack`): [`areas/00-contracts/README.md`](../../areas/00-contracts/README.md) — core fields enumeration · 타입 · required · 의미 단일 진실
- 매니페스트 작성 가이드: [`areas/01-planning/README.md`](../../areas/01-planning/README.md) — scenario 설계 원칙 + α/β/γ 질문 흐름
- `slots[].scenario_mode` override: [`areas/04-gatling-integration/README.md`](../../areas/04-gatling-integration/README.md) — `Config.java` default `LOGIN_ONLY` + 6 enum

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

1. `areas/01-planning/README.md § Scenario 설계 원칙` 의 결정 순서를 사용자에게 질문 (AI 가 진행)
2. 답변에서 `manifest_id` derive (명명 규칙: 영문자·숫자·하이픈·언더스코어)
3. α/β/γ/δ 차원 질문 → bench-stack yml 변형 결정
4. `bench/manifests/<manifest_id>.yaml` 생성 (16 core fields + optional `bench_stack`)
5. `bash areas/02-orchestration/run.sh bench/manifests/<manifest_id>.yaml` 실행

## Out of Scope

- schema validator 코드 → yq + Bash assert 로 충분
- 매니페스트 작성 자동화 도구 → AI 대화형 수집
- 가설 판정 로직 → `areas/03-analysis/analyze/summarize.py`
- run_id 형식 → `areas/00-contracts/README.md` § run_id 형식
