# areas/02-orchestration/lib — 17 함수 → lib 파일 매핑

## 책임 범위

`run.sh` 의 17 함수를 영역별 lib 파일로 분할한다. 함수 구현은 각 lib 파일 참조. 단일 진입점은 `areas/02-orchestration/run.sh` — 사용자/Claude 는 항상 `bash areas/02-orchestration/run.sh <manifest>` 한 줄로 호출하고, `run.sh` 는 orchestration lib와 integration lib를 순서대로 source한다.

## 영역 spec 참조

17 함수 spec 단일 진실은 영역 문서에 lock — 본 README 는 *책임 1줄* 도 *재진술하지 않고* 매핑 표만 둔다.

- 17 함수 spec: [`areas/02-orchestration/README.md` § run.sh 17 함수](../README.md#runsh-17-함수) — 각 함수의 책임·매니페스트 ID 브랜치 의존·신규/v1.0 carry-over 구분 단일 진실
- 신규 6 함수의 명령 단일 진실: [`areas/04-gatling-integration/README.md`](../../04-gatling-integration/README.md) + [`areas/05-realticket-integration/README.md`](../../05-realticket-integration/README.md)
- 이미지 swap·stack restart 절차 (단계 0~4): [`areas/02-orchestration/README.md` § 이미지 swap·stack restart 절차](../README.md#이미지-swapstack-restart-절차)

## 17 함수 → 6 lib 파일 매핑 표

(17 함수 *책임 1줄* 은 [areas/02-orchestration/README.md § run.sh 17 함수](../README.md#runsh-17-함수) 표 참조. 본 표는 *어느 파일에 속하는가*만 lock.)

| 파일 | 함수 |
|---------|------|
| `areas/02-orchestration/lib/util.sh` | `parse_duration` · `manifest_yq` (+ 공통 logger · exit 코드 상수) |
| `areas/02-orchestration/lib/lifecycle.sh` | `admin_login` · `reset_slots` · `get_slot_for_iter` · `write_progress` · `write_iter_meta` · `cleanup_on_exit` |
| `areas/02-orchestration/lib/branch.sh` | `prepare_gatling_branch` · `prepare_realticket_branches` · `apply_untracked_overrides` · `rollback_untracked_overrides` · `restore_main_branches` |
| `areas/04-gatling-integration/lib/gatling.sh` | `run_gatling` · `build_vm_images` · `remove_realticket_stack_if_present` |
| `areas/03-analysis/lib/prom.sh` | `collect_prometheus` |
| `areas/02-orchestration/lib/bench_stack.sh` | `generate_bench_stack_yml` |
| `areas/02-orchestration/run.sh` (lib 외부, 진입점) | `main` |

> 합계: 2 + 6 + 5 + 2 + 1 + 1 + 1 = **17 함수** (02-orchestration § 17 함수 표와 일치).

## source 순서

`run.sh` 의 source 순서:

1. `util.sh` — 공통 logger · exit 코드 상수 (다른 모든 lib 가 의존)
2. `lifecycle.sh` — run 단위 라이프사이클 (`cleanup_on_exit` trap 등록 위해 main 진입 직후 필요)
3. `branch.sh` — 매니페스트 ID 브랜치 분기 (빌드 전)
4. `bench_stack.sh` — `bench-stack/<manifest_id>.yml` 생성 (빌드 전)
5. `gatling.sh` — VM 빌드 + Gatling 실행
6. `prom.sh` — iter 종료 후 Prometheus 수집

## 디렉토리 구조

```
lib/
├── README.md          # 본 파일
├── util.sh            # parse_duration · manifest_yq + logger
├── lifecycle.sh       # admin_login · reset_slots · get_slot_for_iter · write_progress · write_iter_meta · cleanup_on_exit
├── branch.sh          # 5 신규 함수 (매니페스트 ID 브랜치 라이프사이클)
├── gatling.sh         # run_gatling · build_vm_images
├── prom.sh            # collect_prometheus
└── bench_stack.sh     # generate_bench_stack_yml
```

## Out of Scope

- 함수 본체 구현 → 각 lib .sh 파일
- 매니페스트 schema 정의 → 00-contracts § Manifest Schema (불러오기만)
- region/slot/iteration 모델 → 00-contracts § Region·Slot·Iteration 모델 (적용만)
- 분석 모듈 → 03-analysis (run.sh 가 hook 호출만)

