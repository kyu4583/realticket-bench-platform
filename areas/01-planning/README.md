# 01-planning — 매니페스트 수집 흐름

본 영역은 AI가 사용자로부터 매니페스트를 지능적으로 수집하는 방법과 순서를 정의한다. schema 정의는 [00-contracts/README.md](../00-contracts/README.md)에 단일 진실로 lock되어 있으며, 본 파일은 그것을 link로만 참조한다.

---

## 매니페스트 수집 흐름 7단계

사용자가 "매니페스트 시작하자" 또는 동등한 자연어 명령을 내리면 AI는 다음 순서로 진행한다.

| 단계 | 질문 대상 | AI 행동 |
|------|---------|---------|
| (1) | **비교 변수 1개 선택** | 이번 매니페스트가 측정할 단일 비교 차원 확인 (예: 캐싱 유무·Sentinel 적용·Pub/Sub 적용) |
| (2) | **baseline·candidate 슬롯 정의** | `slots[].name` + `targetUrl` + `image_tag` (매니페스트 ID + 슬롯 ID 매핑) |
| (3) | **docker-stack 4 기능 토글 결정** | α(테스트 계정 사전 로그인 yes/no) · β(nest 슬롯 개수 — (2)에서 derive) · γ(Sentinel·autoscaling enabled/disabled) · δ(autoscaler). 사용자가 명시하지 않은 차원은 disabled |
| (4) | **Plan.json region 분할** | `plan_path`가 가리킬 Plan.json의 `regions:` 정의 (Lock #4 단일 진실) |
| (5) | **`queries` 측정 지표** | Prometheus PromQL 목록 + `name`·`unit` |
| (6) | **`hypotheses` PASS/FAIL 기준** | m2 이후 도입. m1 dry-run은 미사용 |
| (7) | **외부 repo 코드 변경 식별** | gatling·RealTicket의 매니페스트별 일회성 코드 변경 (있으면 AI가 매니페스트 ID 브랜치에 자동 적용) + git untracked 빌드 파일 식별 |

---

## Scenario 설계 원칙

시나리오는 한 번에 하나의 비교 변수만 명확히 측정하도록 설계한다. 사용자가 명시하지 않은 기능 토글은 disabled로 유지하고, region 정의는 매니페스트에 직접 쓰지 않고 `plan_path`가 가리키는 Plan.json에만 둔다.

최소 매니페스트는 파이프라인 동작 검증에 집중하고, 전체 매니페스트는 baseline·candidate 슬롯 비교와 `hypotheses:` 판정까지 포함한다.

---

## AI 자동 생성 산출물

위 (1)~(7) 수집 완료 후 AI가 자동으로 생성하는 산출물:

| 산출물 | 위치 | 내용 |
|--------|------|------|
| 매니페스트 본체 | `bench/manifests/<manifest_id>.yaml` | [00-contracts/README.md](../00-contracts/README.md) schema 16 core fields + optional `bench_stack` 충족 |
| docker stack 정의 | `bench-stack/<manifest_id>.yml` (RealTicket repo 매니페스트 ID 브랜치) | base.yml + 활성 토글 patch yq merge |
| Gatling 브랜치 코드 | gatling repo `bench/<manifest_id>` 브랜치 | 일회성 시나리오·PlanConfig 변경 commit |
| RealTicket 브랜치 코드 | RealTicket repo `bench/<manifest_id>` 메타 + 슬롯 브랜치 | yml commit·push |
| VM untracked 파일 | VM `~/web04-RealTicket` 해당 위치 | 빌드에 필요한 git 미추적 파일 적용 |

---

## 매니페스트 등급

| 등급 | 목적 | 특징 |
|------|------|------|
| **최소** | 파이프라인 동작 검증 | `slots` 1개·`iterations` 2~3·`queries` ≥ 1·`hypotheses` 없음 |
| **전체** | 본격 비교 측정 | `slots` 2개·`iterations` ≥ 5 또는 `duration: 6h`·`queries` ≥ 3·`hypotheses` 절 포함 |

두 등급 모두 [00-contracts/README.md](../00-contracts/README.md) schema의 required(✓) 필드는 빠짐없이 채워야 한다.

---

## 운영 정책

- **사용자가 명시하지 않은 토글은 disabled** — α/β/γ/δ 중 사용자가 묻지 않은 차원을 AI 재량으로 활성화 금지
- **region은 매니페스트에서 override 안 함** — `plan_path`로 Plan.json만 가리킴 (Lock #4)
- **slots ≤ 2** — 동시 부하 금지 (Lock #3)
- **매니페스트 작성을 사용자에게 직접 편집 요청 금지** — AI가 수집·생성 주체

---

## 가설 절 패턴 (m2 이후)

매니페스트 `hypotheses:` 필드의 권장 형식:

```yaml
hypotheses:
  - id: H1
    label: "candidate가 baseline 대비 p95 latency 30% 감소"
    metric: p95_response_time         # queries[].name 중 하나
    region: booking                   # Plan.json regions[].name 중 하나 (또는 all)
    direction: lower_is_better
    slot_compare: candidate_vs_baseline
    threshold: 0.30
    pass_when: "improvement >= threshold"
```

가설 판정은 `summarize.py`(03-analysis)가 regions × queries cross product 표를 생성한 후 본 절을 읽어 PASS/FAIL 판정한다. **m1 dry-run에는 `hypotheses:` 미포함이 정상** — 파이프라인 검증 목적이므로 가설 섹션 미생성이 예상 동작.

---

## AI 작업 지침

### AI가 수행하는 행동

1. (1)~(7) 단계를 순서대로 질문하여 답변 수집
2. 수집 완료 후 위 산출물 5개를 자동 생성·적용
3. 사용자에게 생성된 매니페스트 YAML을 검토용으로 제시

### 수정 허용 범위

- 가설 절 패턴 확장 — m2에서 hypotheses 형식이 진화할 때
- 결정 순서 (1)~(7) 갱신 — 새 기능 토글 추가 시
- 변경 시 [00-contracts/README.md](../00-contracts/README.md) schema와 동기 갱신 필수

### 행동 금지

- schema 16 core fields + optional `bench_stack` 정의를 본 파일에 재진술 금지 — [00-contracts/README.md](../00-contracts/README.md)로 link만
- 사용자가 명시하지 않은 토글을 AI 재량으로 활성화 금지
- 매니페스트 작성을 사용자 직접 편집 방식으로 진행 금지
