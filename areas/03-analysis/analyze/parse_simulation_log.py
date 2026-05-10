#!/usr/bin/env python3
"""parse_simulation_log.py — Gatling simulation.log 파서.

Source:
  areas/03-analysis/README.md § 3 분석 모듈
"""
from __future__ import annotations
import argparse, json, re, statistics, sys
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(__file__).parent / "tests" / "fixtures"


_TR_REQ = re.compile(r'<tr\s+id="req_[^"]*"[^>]*>(.*?)</tr>', re.DOTALL)
_ELLIPSED = re.compile(r'class="ellipsed-name">([^<]+)</span>')
_COL_VAL = re.compile(r'class="value[^"]*\bcol-(\d+)"[^>]*>([\d.,]+)<')


def _parse_report_number(raw: str) -> float:
    return float(raw.replace(",", ""))


def _parse_html_stats(iter_dir: str) -> dict[str, Any]:
    """Gatling 3.14+ binary simulation.log 대응 fallback.

    gatling-report/index.html 통계 테이블에서 per-request 집계값 추출.
    col 매핑 (Gatling 3.14 HTML report 기준):
      2=total 3=ok 4=ko 5=%ko 6=cnt/s 7=min 8=p50 9=p75 10=p95 11=p99 12=max 13=mean 14=std dev
    """
    html_path = Path(iter_dir) / "gatling-report" / "index.html"
    if not html_path.exists():
        return {}
    content = html_path.read_text(encoding="utf-8", errors="replace")
    out: dict[str, Any] = {}
    for tr_m in _TR_REQ.finditer(content):
        row = tr_m.group(1)
        name_m = _ELLIPSED.search(row)
        if not name_m:
            continue
        req_name = name_m.group(1).strip()
        cols: dict[int, float] = {}
        for col_m in _COL_VAL.finditer(row):
            cols[int(col_m.group(1))] = _parse_report_number(col_m.group(2))
        total = int(cols.get(2, 0))
        ok    = int(cols.get(3, 0))
        ko    = int(cols.get(4, 0))
        if total == 0:
            continue
        out[req_name] = {
            "total": total,
            "cnt_per_sec": cols.get(6, 0.0),
            "min": cols.get(7, 0.0),
            "p50": cols.get(8, 0.0),
            "p75": cols.get(9, 0.0),
            "p95": cols.get(10, 0.0),
            "p99": cols.get(11, 0.0),
            "max": cols.get(12, 0.0),
            "mean": cols.get(13, 0.0),
            "std_dev": cols.get(14, 0.0),
            "ok": ok,
            "ko": ko,
            "failure_rate": ko / max(1, total),
            "source": "html_report",
        }
    return out


def _decode_request_name(s: str) -> str:
    """latin-1 read 의 byte 시퀀스를 UTF-8 문자열로 재해석.

    simulation.log 는 latin-1 로 열어 binary safe 하게 파싱하지만,
    한글 같은 multi-byte UTF-8 텍스트가 라벨로 들어오면 latin-1 1-byte-per-char 해석으로
    문자열이 깨진다. 가능하면 UTF-8 로 재해석하고 실패 시 원본 유지.
    """
    try:
        return s.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return s


def parse_iter_stats(iter_dir: str) -> dict[str, Any]:
    """iter_dir/simulation.log → stats.json (request_name 별 Gatling report 핵심 집계).

    stats.json 키 = Gatling REQUEST 라인의 request_name (parts[3]).
    simulation.log 에서 REQUEST 탭 구분 라인이 0건이면 빈 dict 반환.
    """
    sim_log = Path(iter_dir) / "simulation.log"
    if not sim_log.exists():
        return {"error": f"simulation.log not found: {sim_log}"}
    req_types: dict[str, dict[str, Any]] = {}
    # latin-1: never crashes on binary files (every byte is valid latin-1).
    with sim_log.open("r", encoding="latin-1") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 7 or parts[0] != "REQUEST":
                continue
            # REQUEST	user	groups	request_name	start_epoch_ms	end_epoch_ms	status
            _, _, _, request_name, start_ms, end_ms, status = parts[:7]
            request_name = _decode_request_name(request_name)
            try:
                start_i = int(start_ms)
                end_i = int(end_ms)
                rt_ms = end_i - start_i
            except ValueError:
                continue
            bucket = req_types.setdefault(request_name, {"latencies": [], "starts": [], "ends": [], "ok": 0, "ko": 0})
            bucket["latencies"].append(rt_ms)
            bucket["starts"].append(start_i)
            bucket["ends"].append(end_i)
            if status == "OK":
                bucket["ok"] += 1
            else:
                bucket["ko"] += 1

    out: dict[str, Any] = {}
    for req_name, data in req_types.items():
        lat = sorted(data["latencies"])
        ok, ko = data["ok"], data["ko"]
        total = ok + ko
        if not lat or total == 0:
            out[req_name] = {
                "total": total,
                "cnt_per_sec": 0.0,
                "min": 0.0,
                "p50": 0.0, "p75": 0.0, "p95": 0.0, "p99": 0.0,
                "max": 0.0,
                "mean": 0.0,
                "std_dev": 0.0,
                "ok": ok, "ko": ko,
                "failure_rate": ko / max(1, total),
                "note": "no_latency_samples",
            }
            continue
        n = len(lat)
        def pct(p: float, _lat: list = lat, _n: int = n) -> float:
            idx = max(0, min(_n - 1, int(p * _n)))
            return float(_lat[idx])
        duration_s = (max(data["ends"]) - min(data["starts"])) / 1000.0
        cnt_per_sec = total / duration_s if duration_s > 0 else float(total)
        out[req_name] = {
            "total": total,
            "cnt_per_sec": cnt_per_sec,
            "min": float(lat[0]),
            "p50": pct(0.5), "p75": pct(0.75), "p95": pct(0.95), "p99": pct(0.99),
            "max": float(lat[-1]),
            "mean": float(statistics.mean(lat)),
            "std_dev": float(statistics.pstdev(lat)),
            "ok": ok, "ko": ko, "failure_rate": ko / max(1, total),
        }

    # simulation.log 에서 REQUEST 0건 → Gatling 3.14+ binary 포맷 의심 → HTML fallback
    if not out:
        out = _parse_html_stats(iter_dir)

    # atomic write
    out_path = Path(iter_dir) / "stats.json"
    tmp = out_path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    tmp.replace(out_path)
    return out


def _extract_html_request_details(simulation_log_path: str, output_path: str,
                                  iter_dir: str | None = None) -> int:
    """텍스트 형식 simulation.log: REQUEST 탭 구분 라인 → JSONL.

    출력 필드: request_name · status · response_time_ms · timestamp_epoch · source
    """
    count = 0
    sim = Path(simulation_log_path)
    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".jsonl.tmp")

    records: list[dict] = []
    with sim.open("r", encoding="latin-1") as src:
        for line in src:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 7 or parts[0] != "REQUEST":
                continue
            _, _, _, request_name, start_ms, end_ms, status = parts[:7]
            request_name = _decode_request_name(request_name)
            try:
                rt_ms = float(int(end_ms) - int(start_ms))
                ts_epoch = int(int(start_ms) / 1000)
            except ValueError:
                continue
            records.append({
                "request_name": request_name,
                "status": status,
                "response_time_ms": rt_ms,
                "timestamp_epoch": ts_epoch,
                "source": "html_stats",
            })

    with tmp.open("w", encoding="utf-8") as dst:
        for rec in records:
            dst.write(json.dumps(rec, ensure_ascii=False) + "\n")
            count += 1
    tmp.replace(out)
    return count


def parse_simulation_log_to_raw_requests(simulation_log_path: str, output_path: str,
                                         iter_dir: str | None = None) -> int:
    """raw_requests.jsonl = every REQUEST line as JSON record.

    Source: areas/03-analysis/README.md
    """
    return _extract_html_request_details(simulation_log_path, output_path, iter_dir)


def _selftest() -> int:
    sim = FIXTURES_DIR / "simulation.log"
    if not sim.exists():
        print(f"FAIL: fixture not found: {sim}", file=sys.stderr)
        return 1
    # parse_iter_stats — keyed by request_name
    stats = parse_iter_stats(str(FIXTURES_DIR))
    if not stats or "좌석 점유" not in stats:
        print(f"FAIL: parse_iter_stats — no '좌석 점유' request_name: {stats}", file=sys.stderr)
        return 1
    if stats["좌석 점유"]["ok"] != 2 or stats["좌석 점유"]["ko"] != 0:
        print(f"FAIL: parse_iter_stats — ok/ko mismatch: {stats['좌석 점유']}", file=sys.stderr)
        return 1
    required_stats = {"total", "cnt_per_sec", "min", "p50", "p75", "p95", "p99", "max", "mean", "std_dev"}
    if not required_stats.issubset(stats["좌석 점유"].keys()):
        print(f"FAIL: stats fields missing: {required_stats - stats['좌석 점유'].keys()}", file=sys.stderr)
        return 1
    # raw_requests.jsonl
    raw_out = FIXTURES_DIR / "raw_requests.jsonl"
    n = parse_simulation_log_to_raw_requests(str(sim), str(raw_out))
    if n != 4:
        print(f"FAIL: expected 4 records, got {n}", file=sys.stderr)
        return 1
    # 5 필드 검증 (region 제거)
    with raw_out.open("r", encoding="utf-8") as f:
        first = json.loads(f.readline())
    required = {"request_name", "status", "response_time_ms", "timestamp_epoch", "source"}
    if not required.issubset(first.keys()):
        print(f"FAIL: missing fields: {required - first.keys()}", file=sys.stderr)
        return 1
    if first["request_name"] != "좌석 점유" or first["source"] != "html_stats":
        print(f"FAIL: request_name/source label missing: {first}", file=sys.stderr)
        return 1
    print("PASS: parse_simulation_log selftest")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Gatling simulation.log parser")
    ap.add_argument("iter_dir", nargs="?", help="iter directory containing simulation.log")
    ap.add_argument("--selftest", action="store_true", help="run self-test with fixtures (no external deps)")
    args = ap.parse_args()
    if args.selftest:
        return _selftest()
    if not args.iter_dir:
        ap.print_help()
        return 1
    stats = parse_iter_stats(args.iter_dir)
    sim = Path(args.iter_dir) / "simulation.log"
    raw = Path(args.iter_dir) / "raw_requests.jsonl"
    n = parse_simulation_log_to_raw_requests(str(sim), str(raw), args.iter_dir)
    print(json.dumps({"stats": stats, "raw_records": n}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
