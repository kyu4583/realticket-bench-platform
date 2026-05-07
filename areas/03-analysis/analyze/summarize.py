#!/usr/bin/env python3
"""summarize.py — slot × request_type 레이턴시 + slot × phase × Prometheus 표 + 가설 판정.

Source: areas/03-analysis/README.md § 3 모듈 spec
"""
from __future__ import annotations
import argparse, ast, json, operator as _op, statistics, sys
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(__file__).parent / "tests" / "fixtures"


def _median_or_none(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


_ALLOWED_BIN = {ast.Add: _op.add, ast.Sub: _op.sub, ast.Mult: _op.mul, ast.Div: _op.truediv}
_ALLOWED_UNARY = {ast.USub: _op.neg, ast.UAdd: _op.pos}


def _safe_arith(expr: str, allowed: dict) -> float:
    """단순 산술만 평가: identifier · 숫자 · + - * / 와 괄호. 그 외는 ValueError."""
    def _eval(node):
        if isinstance(node, ast.Expression):
            return _eval(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.Name) and node.id in allowed:
            return allowed[node.id]
        if isinstance(node, ast.BinOp) and type(node.op) in _ALLOWED_BIN:
            return _ALLOWED_BIN[type(node.op)](_eval(node.left), _eval(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in _ALLOWED_UNARY:
            return _ALLOWED_UNARY[type(node.op)](_eval(node.operand))
        raise ValueError(f"disallowed expression: {ast.dump(node)}")
    return _eval(ast.parse(expr, mode="eval"))


def _build_hypothesis_table(hypotheses: list[dict], slot_metrics: dict) -> list[str]:
    lines = ["", "## 가설 판정", "", "| ID | metric | compare | baseline | candidate | result |", "|----|--------|---------|----------|-----------|--------|"]
    for h in hypotheses:
        metric = h["metric"]
        compare = h["compare"]
        baseline = slot_metrics.get("baseline", {}).get(metric)
        candidate = slot_metrics.get("candidate", {}).get(metric)
        if baseline is None or candidate is None:
            lines.append(f"| {h['id']} | {metric} | {compare} | - | - | SKIP (missing data) |")
            continue
        try:
            allowed = {"baseline": baseline, "candidate": candidate}
            for op in (" <= ", " >= ", " < ", " > "):
                if op in compare:
                    lhs, rhs = compare.split(op, 1)
                    lhs_v = _safe_arith(lhs.strip(), allowed)
                    rhs_v = _safe_arith(rhs.strip(), allowed)
                    ops = {" < ": lhs_v < rhs_v, " <= ": lhs_v <= rhs_v, " > ": lhs_v > rhs_v, " >= ": lhs_v >= rhs_v}
                    result = "PASS" if ops[op] else "FAIL"
                    lines.append(f"| {h['id']} | {metric} | {compare} | {baseline:.3f} | {candidate:.3f} | {result} |")
                    break
            else:
                lines.append(f"| {h['id']} | {metric} | {compare} | {baseline} | {candidate} | INVALID |")
        except Exception as e:
            lines.append(f"| {h['id']} | {metric} | {compare} | - | - | ERROR: {e} |")
    return lines


def _build_prom_phase_table(slot_phase_query: dict[str, dict[str, dict[str, list[float]]]]) -> list[str]:
    """slot × phase × query 평균(median across iters) 표 생성.

    phase 정렬: _iter_total 을 맨 위, 나머지 알파벳순.
    """
    if not slot_phase_query:
        return []

    all_queries: set[str] = set()
    for slot_data in slot_phase_query.values():
        for phase_data in slot_data.values():
            all_queries.update(phase_data.keys())
    sorted_queries = sorted(all_queries)
    if not sorted_queries:
        return []

    lines = ["", "## slot × phase × Prometheus 메트릭 (mean median across iters)", ""]
    header = "| slot | phase | " + " | ".join(sorted_queries) + " |"
    sep = "|------|-------|" + "|".join(["-----"] * len(sorted_queries)) + "|"
    lines.append(header)
    lines.append(sep)

    def _phase_sort_key(p: str) -> tuple[int, str]:
        # _iter_total 우선, 나머지 알파벳순
        return (0, "") if p == "_iter_total" else (1, p)

    for slot in sorted(slot_phase_query.keys()):
        phases_in_slot = sorted(slot_phase_query[slot].keys(), key=_phase_sort_key)
        for phase in phases_in_slot:
            row = [slot, phase]
            for q in sorted_queries:
                vals = slot_phase_query[slot][phase].get(q, [])
                med = _median_or_none(vals)
                row.append(f"{med:.2f}" if med is not None else "-")
            lines.append("| " + " | ".join(row) + " |")
    return lines


def summarize_run(run_dir: str) -> str:
    """run_dir 의 iter-*-{slot}/stats.json + iter-*-{slot}/prom_metrics.json → SUMMARY.md.

    출력 섹션:
      1. slot × request_type 레이턴시 (stats.json — request_name 키)
      2. slot × phase × Prometheus 메트릭 (prom_metrics.json — phase 별 mean median)
      3. 가설 판정 (manifest hypotheses 존재 시)
    """
    try:
        import yaml
    except ImportError:
        return "ERROR: PyYAML not installed"

    run_p = Path(run_dir)
    if not run_p.exists():
        return f"ERROR: run_dir not found: {run_dir}"

    manifest_files = sorted(run_p.glob("manifest.yaml")) or sorted(run_p.parent.glob("*.yaml"))
    hypotheses: list[dict] = []
    manifest_id = run_p.name
    if manifest_files:
        with manifest_files[0].open("r", encoding="utf-8") as f:
            manifest = yaml.safe_load(f) or {}
        hypotheses = manifest.get("hypotheses", []) or []
        manifest_id = manifest.get("manifest_id", run_p.name)

    iter_dirs = [d for d in run_p.iterdir() if d.is_dir() and d.name.startswith("iter-")]

    # slot × request_type 레이턴시 집계 (stats.json)
    slot_reqtype: dict[str, dict[str, dict[str, list[float]]]] = {}
    # slot × phase × query 집계 (prom_metrics.json)
    slot_phase_query: dict[str, dict[str, dict[str, list[float]]]] = {}
    slot_metrics: dict[str, dict[str, float]] = {}

    for d in iter_dirs:
        parts = d.name.split("-", 2)
        slot = parts[2] if len(parts) >= 3 else "?"
        slot_metrics.setdefault(slot, {})

        stats_p = d / "stats.json"
        if stats_p.exists():
            try:
                with stats_p.open("r", encoding="utf-8") as f:
                    stats = json.load(f)
                for req_type, m in stats.items():
                    if not isinstance(m, dict):
                        continue
                    bucket = slot_reqtype.setdefault(slot, {}).setdefault(req_type, {})
                    bucket.setdefault("p50", []).append(m.get("p50", 0))
                    bucket.setdefault("p99", []).append(m.get("p99", 0))
                    bucket.setdefault("failure_rate", []).append(m.get("failure_rate", 0))
            except (json.JSONDecodeError, OSError):
                pass

        prom_p = d / "prom_metrics.json"
        if prom_p.exists():
            try:
                with prom_p.open("r", encoding="utf-8") as f:
                    prom_data = json.load(f)
                # prom_data: {q_name: {phase_name: {mean, max, count}}}
                for q_name, phase_dict in prom_data.items():
                    if not isinstance(phase_dict, dict):
                        continue
                    for phase_name, m in phase_dict.items():
                        if not isinstance(m, dict):
                            continue
                        mean = m.get("mean")
                        if mean is None:
                            continue
                        bucket = slot_phase_query.setdefault(slot, {}).setdefault(phase_name, {}).setdefault(q_name, [])
                        bucket.append(mean)
            except (json.JSONDecodeError, OSError):
                pass

    lines = [
        f"# SUMMARY — {manifest_id}",
        "",
        f"- Run dir: `{run_dir}`",
        f"- Iter dirs: {len(iter_dirs)}",
        "",
        "## slot × request_type 레이턴시",
        "",
    ]
    if not slot_reqtype:
        lines.append("_(no iter directories with stats.json)_")
    else:
        lines.append("| slot | request_type | p50 (median) | p99 (median) | failure_rate (median) |")
        lines.append("|------|-------------|--------------|--------------|----------------------|")
        for slot, req_types in sorted(slot_reqtype.items()):
            for req_type, metrics in sorted(req_types.items()):
                p50_m = _median_or_none(metrics.get("p50", []))
                p99_m = _median_or_none(metrics.get("p99", []))
                fr_m = _median_or_none(metrics.get("failure_rate", []))
                p50_s = f"{p50_m:.1f}" if p50_m is not None else "-"
                p99_s = f"{p99_m:.1f}" if p99_m is not None else "-"
                fr_s = f"{fr_m:.3f}" if fr_m is not None else "-"
                lines.append(f"| {slot} | {req_type} | {p50_s} | {p99_s} | {fr_s} |")

    # phase × Prometheus 표 (prom_metrics.json 가 있는 iter 가 1개 이상이면)
    prom_lines = _build_prom_phase_table(slot_phase_query)
    if prom_lines:
        lines.extend(prom_lines)

    if hypotheses:
        lines.extend(_build_hypothesis_table(hypotheses, slot_metrics))

    out = "\n".join(lines) + "\n"
    out_path = run_p / "SUMMARY.md"
    tmp = out_path.with_suffix(".md.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        f.write(out)
    tmp.replace(out_path)
    return out


def _selftest() -> int:
    run_dir = FIXTURES_DIR / "selftest_run"
    run_dir.mkdir(exist_ok=True)
    iter_dir = run_dir / "iter-1-baseline"
    iter_dir.mkdir(exist_ok=True)
    # stats.json — request_name 키
    stats = {"좌석 점유": {"p50": 50.0, "p75": 75.0, "p95": 95.0, "p99": 99.0, "ok": 100, "ko": 0, "failure_rate": 0.0}}
    (iter_dir / "stats.json").write_text(json.dumps(stats), encoding="utf-8")
    # prom_metrics.json — _iter_total + main_booking phase
    prom = {
        "http_request_rate": {
            "_iter_total":  {"mean": 12.02, "max": 13.0, "count": 5},
            "main_booking": {"mean": 12.50, "max": 13.0, "count": 3},
        }
    }
    (iter_dir / "prom_metrics.json").write_text(json.dumps(prom), encoding="utf-8")

    result = summarize_run(str(run_dir))
    if "ERROR" in result.split("\n")[0]:
        print(f"FAIL: summarize_run error: {result}", file=sys.stderr)
        return 1
    summary_md = (run_dir / "SUMMARY.md").read_text(encoding="utf-8")
    if "slot × request_type 레이턴시" not in summary_md:
        print("FAIL: 레이턴시 표 missing", file=sys.stderr)
        return 1
    if "slot × phase × Prometheus" not in summary_md:
        print("FAIL: phase × Prometheus 표 missing", file=sys.stderr)
        return 1
    if "_iter_total" not in summary_md or "main_booking" not in summary_md:
        print(f"FAIL: phase 행 누락: {summary_md[:300]}", file=sys.stderr)
        return 1
    if "가설 판정" in summary_md:
        print("FAIL: hypotheses 미정의인데 가설 섹션 생성됨", file=sys.stderr)
        return 1
    if "baseline" not in summary_md or "좌석 점유" not in summary_md:
        print(f"FAIL: slot/request_type 누락: {summary_md[:300]}", file=sys.stderr)
        return 1
    print("PASS: summarize selftest (레이턴시 + phase × Prometheus 표 + hypotheses 옵셔널)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="run_dir → SUMMARY.md (레이턴시 + phase × Prometheus + hypotheses)")
    ap.add_argument("run_dir", nargs="?", help="bench/results/<manifest_id>/<run_id>")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return _selftest()
    if not args.run_dir:
        ap.print_help()
        return 1
    result = summarize_run(args.run_dir)
    if result.startswith("ERROR"):
        print(result, file=sys.stderr)
        return 1
    print(f"SUMMARY.md written: {Path(args.run_dir) / 'SUMMARY.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
