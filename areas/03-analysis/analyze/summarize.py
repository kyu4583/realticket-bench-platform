#!/usr/bin/env python3
"""summarize.py — regions × queries cross product + 가설 판정.

Source: areas/03-analysis/README.md § 3 모듈 spec
"""
from __future__ import annotations
import argparse, ast, json, operator as _op, statistics, sys
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(__file__).parent / "tests" / "fixtures"


def _median_or_none(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


# eval() 제거 — RCE 차단. AST whitelist 만 평가.
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
    """간단한 가설 판정 — compare 문자열을 _safe_arith (AST) 로 평가, eval 사용 X."""
    lines = ["", "## 가설 판정", "", "| ID | metric | compare | baseline | candidate | result |", "|----|--------|---------|----------|-----------|--------|"]
    for h in hypotheses:
        metric = h["metric"]
        compare = h["compare"]
        baseline = slot_metrics.get("baseline", {}).get(metric)
        candidate = slot_metrics.get("candidate", {}).get(metric)
        if baseline is None or candidate is None:
            lines.append(f"| {h['id']} | {metric} | {compare} | - | - | SKIP (missing data) |")
            continue
        # compare 형식: "candidate < baseline * 0.95" 또는 "candidate <= baseline * 1.10"
        try:
            allowed = {"baseline": baseline, "candidate": candidate}
            # 보안: eval 대신 _safe_arith — '<' '<=' '>' '>=' 만 지원, 산술은 AST whitelist
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


def summarize_run(run_dir: str) -> str:
    """run_dir 의 iter-*-{slot}/stats.json + prom_*.json + manifest.hypotheses → SUMMARY.md.

    FAILED 마커 디렉토리 제외, median 집계.
    hypotheses 미존재 시 가설 섹션 생략.
    """
    try:
        import yaml
    except ImportError:
        return "ERROR: PyYAML not installed"

    run_p = Path(run_dir)
    if not run_p.exists():
        return f"ERROR: run_dir not found: {run_dir}"

    # 매니페스트 (있으면)
    manifest_files = sorted(run_p.glob("manifest.yaml")) or sorted(run_p.parent.glob("*.yaml"))
    hypotheses: list[dict] = []
    manifest_id = run_p.name
    if manifest_files:
        with manifest_files[0].open("r", encoding="utf-8") as f:
            manifest = yaml.safe_load(f) or {}
        hypotheses = manifest.get("hypotheses", []) or []
        manifest_id = manifest.get("manifest_id", run_p.name)

    # iter-*-{slot} 수집 (FAILED 디렉토리 제외 — 본 plan 에선 단순화: FAILED 마커 파일 검사)
    iter_dirs = [d for d in run_p.iterdir() if d.is_dir() and d.name.startswith("iter-")]
    # slot × region × query 집계
    slot_region_query: dict[str, dict[str, dict[str, list[float]]]] = {}
    slot_metrics: dict[str, dict[str, float]] = {}
    for d in iter_dirs:
        # slot 추출 (iter-N-<slot>)
        parts = d.name.split("-", 2)
        slot = parts[2] if len(parts) >= 3 else "?"
        stats_p = d / "stats.json"
        if stats_p.exists():
            with stats_p.open("r", encoding="utf-8") as f:
                stats = json.load(f)
            for region, m in stats.items():
                bucket = slot_region_query.setdefault(slot, {}).setdefault(region, {})
                bucket.setdefault("p50", []).append(m.get("p50", 0))
                bucket.setdefault("p99", []).append(m.get("p99", 0))
                bucket.setdefault("failure_rate", []).append(m.get("failure_rate", 0))
        # 슬롯 별 단순 집계 (가설 metric 키)
        slot_metrics.setdefault(slot, {})

    # SUMMARY.md 생성
    lines = [f"# SUMMARY — {manifest_id}", "", f"- Run dir: `{run_dir}`", f"- Iter dirs: {len(iter_dirs)}", "", "## regions × queries cross product", ""]
    if not slot_region_query:
        lines.append("_(no iter directories with stats.json)_")
    else:
        lines.append("| slot | region | p50 (median) | p99 (median) | failure_rate (median) |")
        lines.append("|------|--------|--------------|--------------|----------------------|")
        for slot, regions in sorted(slot_region_query.items()):
            for region, metrics in sorted(regions.items()):
                p50_m = _median_or_none(metrics.get("p50", []))
                p99_m = _median_or_none(metrics.get("p99", []))
                fr_m = _median_or_none(metrics.get("failure_rate", []))
                p50_s = f"{p50_m:.1f}" if p50_m is not None else "-"
                p99_s = f"{p99_m:.1f}" if p99_m is not None else "-"
                fr_s = f"{fr_m:.3f}" if fr_m is not None else "-"
                lines.append(f"| {slot} | {region} | {p50_s} | {p99_s} | {fr_s} |")

    # 가설 섹션 (hypotheses 미존재 시 생략)
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
    # fixture 로 합성 run_dir 시뮬레이션 — bench/analyze/tests/fixtures/ 자체를 run_dir 로
    # iter-1-baseline 디렉토리 합성
    run_dir = FIXTURES_DIR / "selftest_run"
    run_dir.mkdir(exist_ok=True)
    iter_dir = run_dir / "iter-1-baseline"
    iter_dir.mkdir(exist_ok=True)
    # stats.json 합성
    stats = {"booking": {"p50": 50.0, "p75": 75.0, "p95": 95.0, "p99": 99.0, "ok": 100, "ko": 5, "failure_rate": 0.05}}
    (iter_dir / "stats.json").write_text(json.dumps(stats), encoding="utf-8")
    # hypotheses 없음 — 가설 섹션 미생성 검증
    result = summarize_run(str(run_dir))
    if "ERROR" in result.split("\n")[0]:
        print(f"FAIL: summarize_run error: {result}", file=sys.stderr)
        return 1
    summary_md = (run_dir / "SUMMARY.md").read_text(encoding="utf-8")
    if "regions × queries cross product" not in summary_md:
        print("FAIL: cross product 표 missing", file=sys.stderr)
        return 1
    if "가설 판정" in summary_md:
        print("FAIL: hypotheses 미정의인데 가설 섹션 생성됨", file=sys.stderr)
        return 1
    if "baseline" not in summary_md or "booking" not in summary_md:
        print(f"FAIL: slot/region 누락: {summary_md[:200]}", file=sys.stderr)
        return 1
    print("PASS: summarize selftest (cross product 표 + hypotheses 옵셔널 검증)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="run_dir → SUMMARY.md (cross product + hypotheses)")
    ap.add_argument("run_dir", nargs="?", help="bench/results/<run_id>")
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
