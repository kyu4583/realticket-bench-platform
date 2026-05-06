# areas/02-orchestration/templates — 4 기능 토글 fragment 시스템

## 책임 범위

`bench-stack/<manifest_id>.yml` (RealTicket repo 의 매니페스트 ID 메타 브랜치 commit) 의 *원천 템플릿*. base.yml + 4 fragment patch + yq deep merge 단일 흐름. 매니페스트의 4 기능 토글이 활성 patch 를 결정.

## 4 기능 토글 (단일 진실)

| 차원 | patch 파일 | 매니페스트 필드 | 의미 (단순 on/off) |
|---|---|---|---|
| α-test-account | `dimensions/alpha-test-account.patch.yml` | `bench_stack.alpha_test_account: true` | redis 가 `redis-test-account` 이미지 사용 (`services.redis-master.image` leaf override) |
| β-dual-slots | `dimensions/beta-dual-slots.patch.yml` | `bench_stack.beta_dual_slots: true` | nest 슬롯 1 → 2 (`nest-candidate` 신규 service 추가, 포트 8081) |
| γ-sentinel | `dimensions/gamma-sentinel.patch.yml` | `bench_stack.gamma_sentinel: true` | Redis Sentinel 활성 (`redis-replica` + `redis-sentinel-1/2/3` 4 services 추가 + `nest-baseline.environment.REDIS_SENTINEL_MODE` override) |
| δ-autoscaler | `dimensions/delta-autoscaler.patch.yml` | `bench_stack.delta_autoscaler: true` | autoscaler 서비스 활성 (`autoscaler` 신규 service 추가) |

**default**: 4 토글 모두 `false` → base 단독 deploy. base.yml 자체는 *완전 비활성 baseline*.

**nest 빌드 invariant:** 모든 차원 조합에서 nest 빌드 = `back/Dockerfile.dev-in-local`. base.yml 의 `nest-baseline.build` 와 β patch 의 `nest-candidate.build` 둘 다 동일 Dockerfile. α patch 는 nest Dockerfile 변경 X.

## 단일 변환 흐름

`areas/02-orchestration/lib/bench_stack.sh:generate_bench_stack_yml` 가 다음 6 단계를 수행한다 (단일 흐름·차원별 case 분기 0건):

1. base.yml 존재 검증 + 매니페스트 4 토글 추출 (default false)
2. 활성 patch enumeration (true 인 토글의 patch 파일 경로 list)
3. 활성 patch 모두 존재 검증 (fail-fast)
4. `yq eval-all '. as $i ireduce ({}; . *+ $i)' base.yml [활성 patches...]` 단일 명령 → MANIFEST_ID/CANDIDATE_IMAGE placeholder sed 후처리 → `$REALTICKET_DIR/bench-stack/<manifest_id>.yml`
5. RealTicket 메타 브랜치 commit (husky bypass 인라인 플래그, die fail-fast)
6. 슬롯 ≥ 2 시 슬롯 브랜치에 cherry-pick (husky bypass 인라인 플래그, die fail-fast)

## 매니페스트 작성 운영 정책

> **Claude 가 매니페스트 작성 시 측정 의도가 토글 활성을 명시 요구하지 않으면 disabled.**

- 사용자가 "테스트 계정 사전 로그인 측정" 명시 → α=true.
- 사용자가 "baseline vs candidate 듀얼 슬롯 비교 측정" 명시 → β=true.
- 사용자가 "Sentinel 페일오버 지연 측정" 명시 → γ=true.
- 사용자가 "autoscaler 실 모드 검증" 명시 → δ=true.
- 사용자가 명시하지 않은 차원은 *항상 disabled*.

`generate_bench_stack_yml` 자체는 *단순 변환기* — AI-driven 결정 0건. *지능 위치* 는 매니페스트 작성 단계 ([`areas/01-planning/README.md § Scenario 설계 원칙`](../../01-planning/README.md#scenario-설계-원칙) 와 cross-link 동기).

## VM 자격증명 환경변수 동기화 컨벤션

`docker-stack.base.yml` 의 mysql / grafana 자격증명은 평문 X — 다음 3 환경변수로 외부화:

| 변수 | 사용 위치 (base.yml) | 의미 |
|---|---|---|
| `VM_REALTICKET_MYSQL_ROOT_PASSWORD` | `mysql.MYSQL_ROOT_PASSWORD` + `nest-baseline.DATABASE_PASSWORD` + `mysql.healthcheck` | mysql root 계정 (3 위치 동기) |
| `VM_REALTICKET_MYSQL_PASSWORD` | `mysql.MYSQL_PASSWORD` (donggle 계정) | mysql 일반 계정 |
| `VM_REALTICKET_GRAFANA_ADMIN_PASSWORD` | `grafana.GF_SECURITY_ADMIN_PASSWORD` | grafana admin |

**원칙:** 로컬 `areas/06-vm-environment/.env.vm` ↔ VM 측 동일 변수 export — *양쪽 값 일치 필수*. base.yml 의 `${VM_REALTICKET_*}` 가 stack deploy 시점 host shell 에서 expand 됨. 값 불일치 시 mysql / grafana 인증 실패 — 사용자 책임.

**fail-fast:** `areas/02-orchestration/lib/bench_stack.sh:generate_bench_stack_yml` 진입부가 3 변수 부재를 즉시 die. bench-stack/<id>.yml 생성 시점에 부재 검출되므로 deploy 단계의 silent 빈 비밀번호 사고 자연 차단.

**Out of m1 scope:** 동기화 *메커니즘* (scp / ssh SendEnv / docker secrets 등) 자체는 m1 범위 밖. 본 컨벤션은 *변수 이름 + 부재 시 die* 까지만 lock — 실 동기화 자동화는 m2+ 검토.

`areas/06-vm-environment/.env.vm.example` 가 3 변수의 dummy 값과 사용법을 lock 한다 (`areas/06-vm-environment/.env.vm` 은 .gitignore — 실 비밀 commit 금지).

## γ-sentinel 활성 매니페스트의 외부 파일 의존

γ patch 의 `redis-replica` / `redis-sentinel-*` 서비스는 RealTicket repo 의 `./redis/replica-entrypoint.sh` / `./redis/sentinel-entrypoint.sh` 두 파일을 bind mount 한다. 두 파일은 dev 브랜치 미추적 ([`areas/05-realticket-integration/README.md`](../../05-realticket-integration/README.md) 참조).

γ=true 매니페스트는 schema 의 `untracked_overrides[]` 절차로 두 파일을 VM 에 배치 *필수*. m1 self dry-run 매니페스트는 γ=false 이므로 본 의존 무관 — base 단독 검증으로 자연 보호.

## 트리

```
templates/
├── README.md                       # 본 파일
├── docker-stack.base.yml           # 4 토글 모두 off 의 완전 비활성 baseline
└── dimensions/                     # 4 fragment patch
    ├── alpha-test-account.patch.yml   # α=true — redis-master.image leaf override
    ├── beta-dual-slots.patch.yml      # β=true — nest-candidate 1 service 추가
    ├── gamma-sentinel.patch.yml       # γ=true — redis-replica + redis-sentinel-1/2/3 추가
    └── delta-autoscaler.patch.yml     # δ=true — autoscaler 추가
```

## Out of Scope

- VM 의 기존 docker-stack-*.yml 시리즈와의 동등성 검증 — VM yml 은 진실 출처 아님.
- nest 빌드 Dockerfile 의 차원별 분기 — 모든 조합에서 `back/Dockerfile.dev-in-local`.
- 5 번째 차원 도입 — 4 차원 lock (m2+ 검토).
- 매니페스트 작성 단계의 AI-driven 차원 결정 — 운영 정책에 따라 사용자/Claude 가 매니페스트 작성 시점에 수동 결정.
- `bench-stack/<manifest_id>.yml` 의 *생성* 자체 → `areas/02-orchestration/lib/bench_stack.sh:generate_bench_stack_yml` 책임.
- 매니페스트 ID 브랜치 commit·push → `areas/02-orchestration/lib/branch.sh` 책임.

## 핵심 결정 출처

- 4 토글 정의 + 운영 정책 lock — [`areas/02-orchestration/README.md` § 이미지 swap·stack restart 절차](../README.md#이미지-swapstack-restart-절차)
- bench-stack 폴더 컨벤션 — [`areas/05-realticket-integration/README.md` § bench-stack yml 컨벤션](../../05-realticket-integration/README.md#bench-stack-yml-컨벤션)
- 이미지 swap·stack restart 절차 — [`areas/02-orchestration/README.md` § 이미지 swap·stack restart 절차](../README.md#이미지-swapstack-restart-절차)
- nest 빌드 Dockerfile 기본값 — [`areas/05-realticket-integration/README.md` § build_vm_images() VM 빌드 3단계](../../05-realticket-integration/README.md#build_vm_images-vm-빌드-3단계) + `areas/04-gatling-integration/lib/gatling.sh:build_vm_images`
