#!/usr/bin/env python3
"""prom_query.py — Prometheus query_range + region 슬라이싱.

Source: areas/03-analysis/README.md § 3 모듈 spec
"""
from __future__ import annotations
import argparse, json, sys
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(__file__).parent / "tests" / "fixtures"


def query_iter_metrics(iter_dir: str, manifest_path: str,
                        offline_response: dict | None = None) -> dict[str, Any]:
    """iter_dir 의 newest prom_*.json + manifest.queries[] + Plan.json regions 로 슬라이싱.

    offline_response: self-test 모드 — Prometheus HTTP 호출 없이 fixture json 사용.
    """
    try:
        import yaml  # PyYAML
    except ImportError:
        return {"error": "PyYAML not installed (pip install -r requirements.txt)"}

    manifest_p = Path(manifest_path)
    if not manifest_p.exists():
        return {"error": f"manifest not found: {manifest_path}"}
    with manifest_p.open("r", encoding="utf-8") as f:
        manifest = yaml.safe_load(f)
    queries = manifest.get("queries", [])
    plan_p = Path(iter_dir) / "Plan.json"
    if not plan_p.exists():
        # fallback: manifest.plan_path 가 fixture 디렉토리 기준
        plan_p = Path(iter_dir) / Path(manifest.get("plan_path", "Plan.json")).name
    if not plan_p.exists():
        return {"error": f"Plan.json not found in {iter_dir}"}
    with plan_p.open("r", encoding="utf-8") as f:
        plan = json.load(f)
    iter_meta_p = Path(iter_dir) / "iter_meta.json"
    if not iter_meta_p.exists():
        return {"error": f"iter_meta.json not found in {iter_dir}"}
    with iter_meta_p.open("r", encoding="utf-8") as f:
        iter_meta = json.load(f)

    iter_start = iter_meta["iter_start_epoch"]
    regions = plan["stats"]["regions"]
    # region 별 시간 윈도우 = iter_start + start_ms..end_ms
    out: dict[str, Any] = {}
    for q in queries:
        q_name = q["name"]
        # offline (self-test) 또는 실제 prom_*.json
        if offline_response is not None:
            resp = offline_response
        else:
            prom_files = sorted(Path(iter_dir).glob("prom_*.json"))
            if not prom_files:
                out[q_name] = {"error": "no prom_*.json"}
                continue
            with prom_files[-1].open("r", encoding="utf-8") as f:
                resp = json.load(f)
        if resp.get("status") != "success":
            out[q_name] = {"error": "prom status != success", "mean": None, "max": None}
            continue
        # region 별 슬라이싱
        per_region: dict[str, Any] = {}
        for region in regions:
            start_epoch = iter_start + region["start_ms"] // 1000
            end_epoch = iter_start + region["end_ms"] // 1000
            values: list[float] = []
            for series in resp["data"]["result"]:
                for ts_str, val_str in series["values"]:
                    ts = int(ts_str)
                    if start_epoch <= ts <= end_epoch:
                        try:
                            values.append(float(val_str))
                        except ValueError:
                            pass
            if values:
                per_region[region["name"]] = {
                    "mean": sum(values) / len(values),
                    "max": max(values),
                    "count": len(values),
                }
            else:
                # count == 0 → error 로 격상하여 SUMMARY.md 가 인지
                per_region[region["name"]] = {
                    "mean": None,
                    "max": None,
                    "count": 0,
                    "error": "no samples in region window",
                }
        out[q_name] = per_region
    return out


def _selftest() -> int:
    manifest = FIXTURES_DIR / "manifest.yaml"
    prom_resp = FIXTURES_DIR / "prom_response.json"
    if not (manifest.exists() and prom_resp.exists()):
        print("FAIL: fixtures missing", file=sys.stderr)
        return 1
    with prom_resp.open("r", encoding="utf-8") as f:
        offline = json.load(f)
    result = query_iter_metrics(str(FIXTURES_DIR), str(manifest), offline_response=offline)
    if "error" in result:
        print(f"FAIL: query_iter_metrics error: {result['error']}", file=sys.stderr)
        return 1
    if "http_request_rate" not in result:
        print(f"FAIL: query name missing in result: {result}", file=sys.stderr)
        return 1
    booking = result["http_request_rate"].get("booking", {})
    if booking.get("count", 0) < 1:
        print(f"FAIL: region 슬라이싱 count = 0: {booking}", file=sys.stderr)
        return 1
    print(f"PASS: prom_query selftest (region 슬라이싱 count={booking['count']}, mean={booking['mean']:.2f})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Prometheus query_range + region 슬라이싱")
    ap.add_argument("--iter", dest="iter_dir", help="iter directory")
    ap.add_argument("--manifest", help="manifest yaml path")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return _selftest()
    if not (args.iter_dir and args.manifest):
        ap.print_help()
        return 1
    result = query_iter_metrics(args.iter_dir, args.manifest)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
