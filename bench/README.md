# bench — 매니페스트 + 결과 디렉토리

## 책임 범위

벤치마크 매니페스트 파일과 실행 결과만 보관한다. 구현 코드(run.sh, lib, analyze, templates)는 모두 `areas/` 하위 영역으로 이동됐다. 본 디렉토리의 구조·스펙 단일 진실은 *모두* `areas/` 의 7 영역 문서에 lock 되어 있고, 본 README 는 *진입점* 역할만 한다.

## 영역 spec 참조

- 결과 디렉토리 구조: [`areas/00-contracts/README.md` § 결과 디렉토리 구조](../areas/00-contracts/README.md) — `bench/results/<manifest_id>/<run_id>/` 트리 정의 단일 진실
- 7 영역 진입: [`areas/README.md`](../areas/README.md) — 7 영역 메타 가이드 (어디부터 읽을지 + 영역 간 호출 그래프)
- 4 Lock 매핑: [`CLAUDE.md` § 4 Lock 원칙 + 영역 매핑](../CLAUDE.md) — Lock #1~#4 책임 영역 표

## 디렉토리 구조

```
bench/
├── README.md             # 본 파일 (bench/ 진입 가이드)
├── manifests/
│   ├── README.md         # 01-planning § Scenario 설계 + 00-contracts § Manifest Schema 인용
│   ├── _example-min.yaml
│   └── _example-full.yaml
└── results/              # gitignored — manifest별 결과 (run_id + iter 디렉토리)
```

## 사용

```bash
# 실행 전 작업 재개 포인터 확인
yq '.workflow_state' bench/manifests/<manifest>.yaml

# 실행
bash areas/02-orchestration/run.sh bench/manifests/<manifest>.yaml

# 진행 상태 polling (fire-and-forget 모드)
cat bench/results/<manifest_id>/<run_id>/progress.json
```

## 환경 변수

`areas/06-vm-environment/.env.example` 의 변수를 복사하여 `areas/06-vm-environment/.env` (gitignored) 에 채운다.

```bash
cp areas/06-vm-environment/.env.example areas/06-vm-environment/.env
```

## Out of Scope

- 영역별 spec 정의 (manifest schema · run.sh 함수 enumeration · 분석 모듈 spec 등) → 7 영역 문서
- run.sh 본체 → `areas/02-orchestration/run.sh`
- lib 함수 → `areas/02-orchestration/lib/`
- 분석 모듈 → `areas/03-analysis/analyze/`
- docker-stack 템플릿 → `areas/02-orchestration/templates/`
- Lock 위배 검증 → `areas/00-contracts/verify-locks.sh`
