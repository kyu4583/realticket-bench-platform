# SUMMARY — self-test

- Run dir: `C:\Users\kxu45\ProgramStudy\realticket-bench-platform\areas\03-analysis\analyze\tests\fixtures\selftest_run`
- Iter dirs: 2

## Gatling metrics by phase (median across iters; Max = peak)

### Gatling phase: main_booking

| request_type | slot | Total | Cnt/s | Min | 50th pct | 75th pct | 95th pct | 99th pct | Max | Mean | Std Dev |
|-------------|------|-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|
| 좌석 점유 | baseline | 100 | 12.34 | 10.0 | 50.0 | 75.0 | 95.0 | 99.0 | 120.0 | 54.0 | 11.2 |
| 좌석 점유 | candidate | 120 | 13.21 | 9.0 | 48.0 | 70.0 | 90.0 | 96.0 | 110.0 | 51.0 | 10.1 |


## Prometheus metrics by phase (mean median, max peak across iters)

### Prometheus phase: _iter_total

| slot | http_request_rate | node_cpu mean | node_cpu max | node_memory mean | node_memory max |
|------|-----|-----|-----|-----|-----|
| baseline | 12.02 | 0.42 | 0.91 | 128.00 MiB | 144.00 MiB |
| candidate | 15.02 | 0.62 | 1.11 | 144.00 MiB | 160.00 MiB |

### Prometheus phase: main_booking

| slot | http_request_rate | node_cpu mean | node_cpu max | node_memory mean | node_memory max |
|------|-----|-----|-----|-----|-----|
| baseline | 12.50 | 0.55 | 0.97 | 150.00 MiB | 160.00 MiB |
| candidate | 15.50 | 0.75 | 1.17 | 160.00 MiB | 176.00 MiB |
