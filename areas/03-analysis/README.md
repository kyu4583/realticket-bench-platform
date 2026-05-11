# 03-analysis — parse · prom_query · summarize

본 영역은 매니페스트 1세트 실행 후 결과 디렉토리를 입력으로 받아 SUMMARY.md를 자동 생성하는 분석 파이프라인을 책임진다.

결과 디렉토리 구조·파일명은 [00-contracts/README.md](../00-contracts/README.md) 참조.

---

## 분석 모듈 스펙

`parse_simulation_log.py`, `prom_query.py`, `summarize.py` 는 run.sh 가 호출하는 자동 분석 모듈이다. `interpret_summary.py` 는 run 완료 후 사용자의 자연어 명령을 받은 AI가 호출하는 post-run 보강 도구다. 출력 파일은 [00-contracts/README.md](../00-contracts/README.md) § 결과 디렉토리 구조의 `iter-N-<slot>/` 트리와 `SUMMARY.md` 계약을 따른다.

### `parse_simulation_log.py`

- **입력:** `iter-N-<slot>/simulation.log` (Gatling 출력 raw 텍스트)
- **출력 1:** `stats.json` — request_name별 Gatling report 핵심 집계 (`total`·`cnt_per_sec`·`min`·`p50`·`p75`·`p95`·`p99`·`max`·`mean`·`std_dev`) + OK/KO 원천값
- **출력 2:** `raw_requests.jsonl` — per-request 1줄 JSON (**0바이트 X 필수**)
- **단독 CLI:** `python areas/03-analysis/analyze/parse_simulation_log.py bench/results/<manifest_id>/<run_id>/iter-1-baseline`
- **책임 경계:** simulation.log REQUEST 라인 파싱만

### `prom_query.py`

- **입력:** 매니페스트의 `queries[]` + `prom_url`·`prom_step` + `iter_meta.json` (`iter_start_epoch` + `iter_end_epoch` 또는 `per_run_ms`) + run_dir 의 `phases.json` (선택)
- **출력:** `iter-N-<slot>/prom_metrics.json` — 구조: `{query_name: {phase_name: {mean, max, count}}}`. `_iter_total` 윈도우는 항상 포함, phase별 윈도우는 `phases.json` 가 있을 때만
- **단독 CLI:** `python areas/03-analysis/analyze/prom_query.py --manifest bench/manifests/<manifest>.yaml --iter bench/results/<manifest_id>/<run_id>/iter-1-baseline`
- **책임 경계:** Prometheus HTTP API 호출만. iter 전체 윈도우 = `[iter_start_epoch, iter_end_epoch]` (실측 우선) 또는 `[iter_start, iter_start+per_run_ms/1000]` (도출 fallback). phase 윈도우 = `[start_ms, end_ms)` (start inclusive, end exclusive)
- **iter timing 메타:** orchestration 이 분석 region 용 `per_run_ms`/`main_booking_ms` 를 `iter_meta.json` 에 기록한다. `per_run_ms` 는 `iter_end_epoch` 가 없을 때만 iter window fallback 으로 쓰고, 정상 결과는 `iter_end_epoch` 실측을 우선한다. duration mode 의 wall-clock 값(`estimated_iter_s`, `measured_iter_s`)은 실행 제어와 추적용 메타이며 Prometheus phase slicing 에 직접 사용하지 않는다.
- **phases.json 스키마**: [00-contracts/README.md § phases.json 스키마](../00-contracts/README.md) 참조

### `summarize.py`

- **입력:** run 디렉토리 전체 — 각 iter의 `stats.json` + `prom_metrics.json` + 매니페스트 `hypotheses:` 절(존재 시)
- **출력:** `bench/results/<manifest_id>/<run_id>/SUMMARY.md` — 3 섹션:
  1. `Gatling metrics by phase` — `stats.json` 기반 (request_name 별 Total·Cnt/s·Min·50th pct·75th pct·95th pct·99th pct·Max·Mean·Std Dev; OK·KO·%KO는 SUMMARY 표에서 제외). `stats.json`에는 phase 축이 없으므로 request_name으로 phase를 보수적으로 추정하고, 실패 시 `unmapped` 표로 분리
  2. `Prometheus metrics by phase` — `prom_metrics.json` 기반 (query별 mean median across iters). phase마다 별도 표를 만들고 같은 phase 안에서 slot 행을 붙임
  3. `가설 판정` — manifest `hypotheses:` 존재 시 PASS/FAIL
- **단독 CLI:** `python areas/03-analysis/analyze/summarize.py bench/results/<manifest_id>/<run_id>`
- **책임 경계:** 집계·표 생성만. 새 메트릭 계산 X — 모든 숫자는 stats.json·prom CSV에서 읽어옴. 기존 `<!-- AI_INTERPRETATION:START -->` 관리 섹션이 있으면 재생성 시 보존한다.

### `interpret_summary.py`

- **입력:** 완료된 run 디렉토리의 `SUMMARY.md` + 매니페스트 `context` + AI가 작성한 해석 Markdown
- **출력:** 같은 `SUMMARY.md` 안의 `<!-- AI_INTERPRETATION:START -->` / `<!-- AI_INTERPRETATION:END -->` 관리 섹션 추가 또는 교체
- **단독 CLI:**
  - 컨텍스트 확인: `python areas/03-analysis/analyze/interpret_summary.py bench/results/<manifest_id>/<run_id> --context`
  - 해석 삽입: `python areas/03-analysis/analyze/interpret_summary.py bench/results/<manifest_id>/<run_id> --file interpretation.md`
- **책임 경계:** LLM 호출 없음. 자연어 해석은 완료 후 사용자의 명령을 받은 AI가 작성하고, 이 모듈은 파일 삽입/교체만 담당한다. 기본적으로 `COMPLETED` run 에만 적용하며 실패 run 을 분석하려면 `--allow-failed` 를 명시한다.
- **AI 해석 정리:** `Purpose-based Interpretation` 관리 섹션 안에는 마지막에 `### 정리` 문단을 포함한다. 고정 템플릿은 아니며, 사용자가 예시로 남긴 정리 문단의 문체·표현 수준·방식을 따른다. 비교 기준을 먼저 짧게 고정하고, 핵심 latency/resource 지표를 raw value + % delta 로 직접 쓰며, 지표가 뒷받침하지 않는 주장은 피한다.

---

## 결과 읽는 방법

| 목적 | 방법 |
|------|------|
| 전체 결과 확인 | `bench/results/<manifest_id>/<run_id>/SUMMARY.md` — phase별 Gatling metrics + phase별 Prometheus metrics + 가설 판정 |
| 목적 기반 해석 추가 | `interpret_summary.py --context` 로 매니페스트 목적을 확인한 뒤 AI가 해석 Markdown을 작성하고 `interpret_summary.py --file` 로 `SUMMARY.md` 관리 섹션을 추가/교체 |
| 세부 집계 (요청별) | `iter-N-<slot>/stats.json` (request_name 키) |
| 세부 집계 (Prometheus phase 슬라이스) | `iter-N-<slot>/prom_metrics.json` |
| 시뮬레이션 단계 정의 | `<run_dir>/phases.json` |
| per-request 분석 | `iter-N-<slot>/raw_requests.jsonl` (1줄 = 1 요청) |
| Prometheus 시계열 | `iter-N-<slot>/prometheus_<query>.csv` |

---

## raw_requests.jsonl 형식

1줄 = 1 HTTP 요청. 필수 필드 (5개):

```json
{"request_name": "좌석 점유", "status": "OK", "response_time_ms": 42.0, "timestamp_epoch": 1777663801, "source": "html_stats"}
```

**회귀 방지:** `parse_simulation_log.py` 재작성 시 `stats.json`만 출력하고 `raw_requests.jsonl`을 누락하면 회귀 — 파일이 0바이트인 것도 동일하게 회귀.

---

## 가설 판정 입력

`summarize.py`는 매니페스트의 `hypotheses:` 절이 있을 때만 가설 판정 표를 만든다. `hypotheses:`가 없으면 phase별 Gatling/Prometheus metrics 표만 출력하고 가설 섹션은 만들지 않는다.

---

## 불변 조건

- `raw_requests.jsonl` 출력 유지 필수 — 누락 시 dry-run 검증 실패
- 출력 파일은 모두 텍스트(JSON·JSONL·CSV·MD) — GUI 분석 도구·Excel 출력 추가 금지
- 모든 집계 숫자는 stats.json·prom CSV에서 읽어옴 — summarize.py 자체 latency 재계산 금지
- `hypotheses:` 필드 부재 시 가설 섹션 생성 금지 — 부재 시 생략이 정상 동작
- `run.sh` 종료 훅에서 AI 해석을 호출하지 않음 — post-run 자연어 명령으로만 `interpret_summary.py` 를 사용

---

## AI 작업 지침

### AI가 분석 결과를 읽는 방법

- **결과 확인 시:** `bench/results/<manifest_id>/<run_id>/SUMMARY.md`를 먼저 읽는다
- **세부 분석 필요 시:** `iter-N-<slot>/stats.json`과 `raw_requests.jsonl`을 직접 파싱 (stats.json 키 = request_name)

### AI가 분석 모듈을 수정하는 시점

- **parse_simulation_log.py 수정:** Gatling simulation.log 포맷 변경 시
- **prom_query.py 수정:** Prometheus query 추가·PromQL 형식 변경 시
- **summarize.py 수정:** cross product 표 형식 변경·가설 판정 로직 보강 시

### 행동 금지

- GUI Gatling 리포트 HTML 직접 클릭·스크레이핑 도구 추가 금지
- hypotheses 필드 부재 시 가설 섹션 생성 금지
