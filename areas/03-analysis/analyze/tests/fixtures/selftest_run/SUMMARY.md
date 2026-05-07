# SUMMARY — self-test

- Run dir: `/mnt/c/Users/kxu45/ProgramStudy/realticket-bench-platform/areas/03-analysis/analyze/tests/fixtures/selftest_run`
- Iter dirs: 1

## slot × request_type 레이턴시

| slot | request_type | p50 (median) | p99 (median) | failure_rate (median) |
|------|-------------|--------------|--------------|----------------------|
| baseline | 좌석 점유 | 50.0 | 99.0 | 0.000 |

## slot × phase × Prometheus 메트릭 (mean median across iters)

| slot | phase | http_request_rate |
|------|-------|-----|
| baseline | _iter_total | 12.02 |
| baseline | main_booking | 12.50 |
