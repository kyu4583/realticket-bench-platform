# 03-analysis — parse · prom_query · summarize

본 영역은 매니페스트 1세트 실행 후 결과 디렉토리를 입력으로 받아 SUMMARY.md를 자동 생성하는 분석 파이프라인을 책임진다.

region 단일 진실(Lock #4)의 원천은 [04-gatling-integration](../04-gatling-integration/README.md)이며, 본 영역은 동일 region 키로 읽고 슬라이싱만 한다.

결과 디렉토리 구조·파일명·region 키는 [00-contracts/README.md](../00-contracts/README.md) 참조.

---

## 3 모듈 스펙

세 모듈은 iter 단위로 호출되며(run.sh 또는 단독 실행), 출력 파일은 [00-contracts/README.md](../00-contracts/README.md) § 결과 디렉토리 구조의 `iter-N-<slot>/` 트리에 lock된 파일명을 따른다.

### `parse_simulation_log.py`

- **입력:** `iter-N-<slot>/simulation.log` (Gatling 출력 raw 텍스트)
- **출력 1:** `stats.json` — 요청 종류별 count·OK/KO·평균/p50/p99/p999 latency, region 라벨 부착
- **출력 2:** `raw_requests.jsonl` — per-request 1줄 JSON, region 라벨 부착 (**0바이트 X 필수**)
- **단독 CLI:** `python areas/03-analysis/analyze/parse_simulation_log.py bench/results/<run_id>/iter-1-baseline`
- **책임 경계:** simulation.log 그룹 헤더에서 region 라벨 읽기만 — region 정의 생성 X (Lock #4 소비 측)

### `prom_query.py`

- **입력:** 매니페스트의 `queries[]` + `prom_url`·`prom_step` + iter 디렉토리의 region 시간 범위
- **출력:** `prometheus_<query_name>.csv` (timestamp·value 컬럼, region별)
- **단독 CLI:** `python areas/03-analysis/analyze/prom_query.py --manifest bench/manifests/<manifest>.yaml --iter bench/results/<run_id>/iter-1-baseline`
- **책임 경계:** Prometheus HTTP API 호출만. region 슬라이싱 단위로 query_range 호출 — region을 timestamp 범위로 변환할 때 parse 출력의 simulation.log region 시간을 단일 진실로 사용

### `summarize.py`

- **입력:** run 디렉토리 전체 — 각 iter의 `stats.json` + `prometheus_<query>.csv` + 매니페스트 `hypotheses:` 절(존재 시)
- **출력:** `bench/results/<run_id>/SUMMARY.md` — regions × queries cross product 표 + 슬롯 비교 + 가설 판정 PASS/FAIL
- **단독 CLI:** `python areas/03-analysis/analyze/summarize.py bench/results/<run_id>`
- **책임 경계:** 집계·표 생성만. 새 메트릭 계산 X — 모든 숫자는 stats.json·prom CSV에서 읽어옴

---

## 결과 읽는 방법

| 목적 | 방법 |
|------|------|
| 전체 결과 확인 | `bench/results/<run_id>/SUMMARY.md` — regions × queries cross product 표 + 가설 판정 |
| 세부 집계 | `iter-N-<slot>/stats.json` |
| per-request 분석 | `iter-N-<slot>/raw_requests.jsonl` (1줄 = 1 요청, region 라벨 포함) |
| Prometheus 시계열 | `iter-N-<slot>/prometheus_<query>.csv` |

---

## raw_requests.jsonl 형식

1줄 = 1 HTTP 요청. 필수 필드:

```json
{"request_name": "booking", "start_ms": 12345, "end_ms": 12890, "status": "OK", "region": "booking", "slot": "baseline", "iter": 1}
```

**회귀 방지:** `parse_simulation_log.py` 재작성 시 `stats.json`만 출력하고 `raw_requests.jsonl`을 누락하면 회귀 — 파일이 0바이트인 것도 동일하게 회귀.

---

## Region — 소비 측

본 영역은 region을 정의하지 않는다. Gatling PlanGenerator가 만든 Plan.json과 simulation.log의 region 라벨을 읽어 `stats.json`, `raw_requests.jsonl`, Prometheus 슬라이스에 같은 키를 붙인다.

region 이름을 분석 모듈에서 재명명하거나 새 region 모델을 만들면 Lock #4 위배다.

---

## 가설 판정 입력

`summarize.py`는 매니페스트의 `hypotheses:` 절이 있을 때만 가설 판정 표를 만든다. `hypotheses:`가 없으면 regions × queries cross product 결과만 출력하고 가설 섹션은 만들지 않는다.

---

## 불변 조건

- `raw_requests.jsonl` 출력 유지 필수 — 누락 시 dry-run 검증 실패
- region 라벨은 simulation.log에서 읽기만 — region 재정의·재명명 금지 (Lock #4 소비 측)
- 출력 파일은 모두 텍스트(JSON·JSONL·CSV·MD) — GUI 분석 도구·Excel 출력 추가 금지
- 모든 집계 숫자는 stats.json·prom CSV에서 읽어옴 — summarize.py 자체 latency 재계산 금지
- `hypotheses:` 필드 부재 시 가설 섹션 생성 금지 — 부재 시 생략이 정상 동작

---

## AI 작업 지침

### AI가 분석 결과를 읽는 방법

- **결과 확인 시:** `bench/results/<run_id>/SUMMARY.md`를 먼저 읽는다
- **세부 분석 필요 시:** `iter-N-<slot>/stats.json`과 `raw_requests.jsonl`을 직접 파싱
- **region 키 참조:** simulation.log의 group 라벨이 region 이름 — [00-contracts/README.md](../00-contracts/README.md) § Region 모델의 `<region>-<slot>-<iter>` 패턴으로 식별

### AI가 분석 모듈을 수정하는 시점

- **parse_simulation_log.py 수정:** Gatling simulation.log 포맷 변경 시
- **prom_query.py 수정:** Prometheus query 추가·PromQL 형식 변경 시
- **summarize.py 수정:** cross product 표 형식 변경·가설 판정 로직 보강 시

### 행동 금지

- region 시간 구간을 분석 모듈 내부에 하드코딩 금지 (Lock #4 위배)
- GUI Gatling 리포트 HTML 직접 클릭·스크레이핑 도구 추가 금지
- hypotheses 필드 부재 시 가설 섹션 생성 금지
