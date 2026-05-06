# areas/03-analysis/analyze — 3 분석 모듈

## 책임 범위

3 분석 모듈 (`parse_simulation_log` · `prom_query` · `summarize`) — iter 디렉토리 단위 호출. `raw_requests.jsonl` per-request 출력 포함 (회귀 방지). 3 .py + `requirements.txt` + self-test fixture를 포함한다.

## 영역 spec 참조

3 모듈의 함수 시그니처·입출력·CLI 단일 진실은 영역 문서에 lock — 본 README 는 *spec 재진술 X · link O*.

- 3 모듈 spec: [`areas/03-analysis/README.md` § 3 모듈 spec](../README.md#3-모듈-스펙) — 각 모듈의 메인 함수 · 입력 · 출력 · CLI 인자 단일 진실
- raw_requests.jsonl per-request 출력: `parse_simulation_log_to_raw_requests` 의 region 라벨 부착
- Region — 소비 측 (Lock #4): [`areas/03-analysis/README.md` § Region — 소비 측](../README.md#region--소비-측)
- 가설 판정 입력: [`areas/03-analysis/README.md` § 가설 판정 입력](../README.md#가설-판정-입력)

## venv 부트스트랩

```bash
# Windows (Git Bash)
python -m venv bench/analyze/.venv && \
  source bench/analyze/.venv/Scripts/activate && \
  pip install -r bench/analyze/requirements.txt

# POSIX (Linux/macOS — VM 측 분석 시)
python3 -m venv bench/analyze/.venv && \
  source bench/analyze/.venv/bin/activate && \
  pip install -r bench/analyze/requirements.txt
```

`.venv/` 는 `bench/.gitignore` 에 등재됨. `requirements.txt`: `PyYAML` (매니페스트 읽기) · `requests` (Prometheus query_range).

## 단독 호출

각 모듈은 `--help` + `--selftest` 로 단독 호출 가능. self-test 는 합성 fixture (`bench/analyze/tests/fixtures/`, **고정 경로** — Python `tempfile` 회피) 로 외부 의존 없이 PASS.

```bash
python bench/analyze/parse_simulation_log.py --selftest
python bench/analyze/prom_query.py --selftest
python bench/analyze/summarize.py --selftest
```

## 디렉토리 구조

```
analyze/
├── README.md                     # 본 파일
├── requirements.txt              # PyYAML + requests
├── parse_simulation_log.py       # parse_iter_stats + parse_simulation_log_to_raw_requests
├── prom_query.py                 # query_iter_metrics
├── summarize.py                  # summarize_run
└── tests/
    ├── .gitkeep
    └── fixtures/                 # self-test 합성 입력 (고정 경로)
```

## raw_requests.jsonl 라인 형식

per-record JSON 1줄. region 라벨 부착으로 사후 재분석 시 시간 구간 식별 가능. 자세한 필드 정의는 [03-analysis](../README.md) 참조.

## Out of Scope

- region/slot/iteration *모델 정의* → 00-contracts § Region·Slot·Iteration 모델 (소비만)
- 매니페스트 schema → 00-contracts § Manifest Schema (`hypotheses[]` 절 입력만 소비)
- run.sh 의 hook 호출 → 02-orchestration (`run.sh main` 의 마지막 단계에서 `summarize.py` 호출)
- v1.0 audit § tech_debt #6 한계 (per-request 시각 미제공, Gatling 3.14.x string-interning) → 모듈 docstring + `source: "html_stats"` 필드로 명시

