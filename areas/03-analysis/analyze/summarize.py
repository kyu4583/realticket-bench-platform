#!/usr/bin/env python3
"""summarize.py — phase별 Gatling/Prometheus metrics 표 + 가설 판정.

Source: areas/03-analysis/README.md § 분석 모듈 스펙
"""
from __future__ import annotations
import argparse, ast, json, operator as _op, statistics, sys
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(__file__).parent / "tests" / "fixtures"

GATLING_SUMMARY_COLUMNS: list[tuple[str, str, str]] = [
    ("total", "Total", "median"),
    ("cnt_per_sec", "Cnt/s", "median"),
    ("min", "Min", "median"),
    ("p50", "50th pct", "median"),
    ("p75", "75th pct", "median"),
    ("p95", "95th pct", "median"),
    ("p99", "99th pct", "median"),
    ("max", "Max", "max"),
    ("mean", "Mean", "median"),
    ("std_dev", "Std Dev", "median"),
]

AI_INTERPRETATION_START = "<!-- AI_INTERPRETATION:START -->"
AI_INTERPRETATION_END = "<!-- AI_INTERPRETATION:END -->"


def _median_or_none(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def _max_or_none(values: list[float]) -> float | None:
    return max(values) if values else None


def _human_bytes(value: float) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    size = float(value)
    unit = units[0]
    for unit in units:
        if abs(size) < 1024 or unit == units[-1]:
            break
        size /= 1024
    if unit == "B":
        return f"{size:.0f} {unit}"
    return f"{size:.2f} {unit}"


def _is_bytes_metric(query_name: str, query_units: dict[str, str]) -> bool:
    unit = (query_units.get(query_name) or "").lower()
    return unit in {"b", "byte", "bytes"} or "memory" in query_name.lower()


def _format_prom_value(query_name: str, value: float, query_units: dict[str, str]) -> str:
    if _is_bytes_metric(query_name, query_units):
        return _human_bytes(value)
    return f"{value:.2f}"


def _format_gatling_value(metric_name: str, value: float) -> str:
    if metric_name == "total":
        return f"{value:.0f}"
    if metric_name == "cnt_per_sec":
        return f"{value:.2f}"
    return f"{value:.1f}"


def _extract_ai_interpretation(summary_text: str) -> str:
    start = summary_text.find(AI_INTERPRETATION_START)
    end = summary_text.find(AI_INTERPRETATION_END)
    if start == -1 or end == -1 or end < start:
        return ""
    end += len(AI_INTERPRETATION_END)
    return summary_text[start:end].strip()


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


def _phase_sort_key(p: str) -> tuple[int, str]:
    # _iter_total 우선, 나머지 알파벳순
    return (0, "") if p == "_iter_total" else (1, p)


def _prom_columns(
    slot_phase_query: dict[str, dict[str, dict[str, dict[str, list[float]]]]],
    query_units: dict[str, str],
) -> list[tuple[str, str, str]]:
    if not slot_phase_query:
        return []

    all_queries: set[str] = set()
    for slot_data in slot_phase_query.values():
        for phase_data in slot_data.values():
            all_queries.update(phase_data.keys())
    sorted_queries = sorted(all_queries)
    if not sorted_queries:
        return []

    columns = []
    for q in sorted_queries:
        if q == "node_cpu" or _is_bytes_metric(q, query_units):
            columns.append((f"{q} mean", q, "mean"))
            columns.append((f"{q} max", q, "max"))
        else:
            columns.append((q, q, "mean"))
    return columns


def _prom_aggregate(values: list[float], stat: str) -> float | None:
    return _max_or_none(values) if stat == "max" else _median_or_none(values)


def _slot_sort_key(slot: str) -> tuple[int, str]:
    priority = {"baseline": 0, "candidate": 1}
    return (priority.get(slot, 2), slot)


def _tokenize_label(label: str) -> set[str]:
    cleaned = "".join(ch.lower() if ch.isalnum() else " " for ch in label)
    return {token for token in cleaned.split() if token}


def _infer_gatling_phase(request_type: str, phase_names: list[str]) -> str:
    """stats.json에는 phase 축이 없으므로 request_name에서 가장 그럴듯한 phase를 고른다."""
    usable_phases = [p for p in phase_names if p != "_iter_total"]
    if not usable_phases:
        return "_iter_total"

    req_lower = request_type.lower()
    is_auth_request = any(token in req_lower for token in ("권한", "입장", "확인", "auth"))
    if is_auth_request:
        for phase in usable_phases:
            phase_lower = phase.lower()
            if any(token in phase_lower for token in ("권한", "입장", "확인", "auth")):
                return phase

    is_booking_request = any(token in req_lower for token in ("sse", "섹션", "전환", "좌석", "예매", "예약"))
    if is_booking_request:
        for phase in usable_phases:
            phase_lower = phase.lower()
            if any(token in phase_lower for token in ("sse", "구독", "예매", "booking", "main")):
                return phase

    req_tokens = _tokenize_label(request_type)
    best_phase = ""
    best_score = 0
    for phase in usable_phases:
        score = len(req_tokens & _tokenize_label(phase))
        if score > best_score:
            best_score = score
            best_phase = phase
    return best_phase if best_score else "unmapped"


def _ordered_phase_names(slot_phase_query: dict[str, dict[str, dict[str, dict[str, list[float]]]]]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for slot in sorted(slot_phase_query.keys(), key=_slot_sort_key):
        for phase in slot_phase_query[slot].keys():
            if phase in seen:
                continue
            seen.add(phase)
            ordered.append(phase)
    return ordered


def _build_gatling_phase_tables(
    slot_reqtype: dict[str, dict[str, dict[str, list[float]]]],
    phase_names: list[str],
) -> list[str]:
    if not slot_reqtype:
        return ["_(no iter directories with stats.json)_"]

    phase_req_slot: dict[str, dict[str, dict[str, dict[str, list[float]]]]] = {}
    for slot, req_types in slot_reqtype.items():
        for req_type, metrics in req_types.items():
            phase = _infer_gatling_phase(req_type, phase_names)
            phase_req_slot.setdefault(phase, {}).setdefault(req_type, {})[slot] = metrics

    ordered_phases = [p for p in phase_names if p in phase_req_slot]
    ordered_phases.extend(sorted(p for p in phase_req_slot if p not in set(ordered_phases)))

    lines = ["## Gatling metrics by phase (median across iters; Max = peak)", ""]
    for phase in ordered_phases:
        lines.extend([f"### Gatling phase: {phase}", ""])
        header = "| request_type | slot | " + " | ".join(label for _, label, _ in GATLING_SUMMARY_COLUMNS) + " |"
        sep = "|-------------|------|" + "|".join(["-----"] * len(GATLING_SUMMARY_COLUMNS)) + "|"
        lines.append(header)
        lines.append(sep)
        for req_type in sorted(phase_req_slot[phase].keys()):
            for slot in sorted(phase_req_slot[phase][req_type].keys(), key=_slot_sort_key):
                metrics = phase_req_slot[phase][req_type][slot]
                row = [req_type, slot]
                for metric_name, _, agg in GATLING_SUMMARY_COLUMNS:
                    values = metrics.get(metric_name, [])
                    metric_value = _max_or_none(values) if agg == "max" else _median_or_none(values)
                    row.append(_format_gatling_value(metric_name, metric_value) if metric_value is not None else "-")
                lines.append("| " + " | ".join(row) + " |")
        lines.append("")
    return lines


def _build_prom_phase_table(
    slot_phase_query: dict[str, dict[str, dict[str, dict[str, list[float]]]]],
    query_units: dict[str, str],
) -> list[str]:
    """slot × phase × query 표 생성.

    phase 정렬: _iter_total 을 맨 위, 나머지 알파벳순.
    """
    columns = _prom_columns(slot_phase_query, query_units)
    if not columns:
        return []

    lines = ["", "## Prometheus metrics by phase (mean median, max peak across iters)", ""]
    phases = _ordered_phase_names(slot_phase_query)
    for phase in phases:
        lines.extend([f"### Prometheus phase: {phase}", ""])
        header = "| slot | " + " | ".join(label for label, _, _ in columns) + " |"
        sep = "|------|" + "|".join(["-----"] * len(columns)) + "|"
        lines.append(header)
        lines.append(sep)
        for slot in sorted(slot_phase_query.keys(), key=_slot_sort_key):
            if phase not in slot_phase_query[slot]:
                continue
            row = [slot]
            for _, q, stat in columns:
                vals = slot_phase_query[slot][phase].get(q, {}).get(stat, [])
                agg = _prom_aggregate(vals, stat)
                row.append(_format_prom_value(q, agg, query_units) if agg is not None else "-")
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")
    return lines


def summarize_run(run_dir: str) -> str:
    """run_dir 의 iter-*-{slot}/stats.json + iter-*-{slot}/prom_metrics.json → SUMMARY.md.

    출력 섹션:
      1. phase별 Gatling metrics (stats.json — request_name 키, request_name에서 phase 추정)
      2. phase별 Prometheus metrics (prom_metrics.json — phase 별 mean median + selected max)
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
    query_units: dict[str, str] = {}
    manifest_id = run_p.name
    if manifest_files:
        with manifest_files[0].open("r", encoding="utf-8") as f:
            manifest = yaml.safe_load(f) or {}
        hypotheses = manifest.get("hypotheses", []) or []
        for q in manifest.get("queries", []) or []:
            if isinstance(q, dict) and q.get("name"):
                query_units[str(q["name"])] = str(q.get("unit") or "")
        manifest_id = manifest.get("manifest_id", run_p.name)

    iter_dirs = [d for d in run_p.iterdir() if d.is_dir() and d.name.startswith("iter-")]

    # slot × request_type Gatling 집계 (stats.json)
    slot_reqtype: dict[str, dict[str, dict[str, list[float]]]] = {}
    # slot × phase × query 집계 (prom_metrics.json)
    slot_phase_query: dict[str, dict[str, dict[str, dict[str, list[float]]]]] = {}
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
                    for metric_name, _, _ in GATLING_SUMMARY_COLUMNS:
                        value = m.get(metric_name)
                        if value is None:
                            continue
                        try:
                            metric_float = float(value)
                        except (TypeError, ValueError):
                            continue
                        bucket.setdefault(metric_name, []).append(metric_float)
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
                        bucket = slot_phase_query.setdefault(slot, {}).setdefault(phase_name, {}).setdefault(q_name, {})
                        for stat_name in ("mean", "max"):
                            stat_value = m.get(stat_name)
                            if stat_value is None:
                                continue
                            try:
                                stat_float = float(stat_value)
                            except (TypeError, ValueError):
                                continue
                            bucket.setdefault(stat_name, []).append(stat_float)
            except (json.JSONDecodeError, OSError):
                pass

    lines = [
        f"# SUMMARY — {manifest_id}",
        "",
        f"- Run dir: `{run_dir}`",
        f"- Iter dirs: {len(iter_dirs)}",
        "",
    ]

    phase_names = _ordered_phase_names(slot_phase_query)
    lines.extend(_build_gatling_phase_tables(slot_reqtype, phase_names))

    # phase × Prometheus 표 (prom_metrics.json 가 있는 iter 가 1개 이상이면)
    prom_lines = _build_prom_phase_table(slot_phase_query, query_units)
    if prom_lines:
        lines.extend(prom_lines)

    if hypotheses:
        lines.extend(_build_hypothesis_table(hypotheses, slot_metrics))

    while lines and lines[-1] == "":
        lines.pop()

    out_path = run_p / "SUMMARY.md"
    preserved_interpretation = ""
    if out_path.exists():
        preserved_interpretation = _extract_ai_interpretation(out_path.read_text(encoding="utf-8"))

    out = "\n".join(lines)
    if preserved_interpretation:
        out = out.rstrip() + "\n\n" + preserved_interpretation
    out += "\n"
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
    candidate_iter_dir = run_dir / "iter-2-candidate"
    candidate_iter_dir.mkdir(exist_ok=True)
    # stats.json — request_name 키
    stats = {
        "좌석 점유": {
            "total": 100,
            "cnt_per_sec": 12.34,
            "min": 10.0,
            "p50": 50.0,
            "p75": 75.0,
            "p95": 95.0,
            "p99": 99.0,
            "max": 120.0,
            "mean": 54.0,
            "std_dev": 11.2,
            "ok": 100,
            "ko": 0,
            "failure_rate": 0.0,
        }
    }
    (iter_dir / "stats.json").write_text(json.dumps(stats), encoding="utf-8")
    candidate_stats = {
        "좌석 점유": {
            "total": 120,
            "cnt_per_sec": 13.21,
            "min": 9.0,
            "p50": 48.0,
            "p75": 70.0,
            "p95": 90.0,
            "p99": 96.0,
            "max": 110.0,
            "mean": 51.0,
            "std_dev": 10.1,
            "ok": 120,
            "ko": 0,
            "failure_rate": 0.0,
        }
    }
    (candidate_iter_dir / "stats.json").write_text(json.dumps(candidate_stats), encoding="utf-8")
    # prom_metrics.json — _iter_total + main_booking phase
    prom = {
        "http_request_rate": {
            "_iter_total":  {"mean": 12.02, "max": 13.0, "count": 5},
            "main_booking": {"mean": 12.50, "max": 13.0, "count": 3},
        },
        "node_cpu": {
            "_iter_total":  {"mean": 0.42, "max": 0.91, "count": 5},
            "main_booking": {"mean": 0.55, "max": 0.97, "count": 3},
        },
        "node_memory": {
            "_iter_total":  {"mean": 134217728, "max": 150994944, "count": 5},
            "main_booking": {"mean": 157286400, "max": 167772160, "count": 3},
        }
    }
    (iter_dir / "prom_metrics.json").write_text(json.dumps(prom), encoding="utf-8")
    candidate_prom = {
        "http_request_rate": {
            "_iter_total":  {"mean": 15.02, "max": 16.0, "count": 5},
            "main_booking": {"mean": 15.50, "max": 17.0, "count": 3},
        },
        "node_cpu": {
            "_iter_total":  {"mean": 0.62, "max": 1.11, "count": 5},
            "main_booking": {"mean": 0.75, "max": 1.17, "count": 3},
        },
        "node_memory": {
            "_iter_total":  {"mean": 150994944, "max": 167772160, "count": 5},
            "main_booking": {"mean": 167772160, "max": 184549376, "count": 3},
        }
    }
    (candidate_iter_dir / "prom_metrics.json").write_text(json.dumps(candidate_prom), encoding="utf-8")

    result = summarize_run(str(run_dir))
    if "ERROR" in result.split("\n")[0]:
        print(f"FAIL: summarize_run error: {result}", file=sys.stderr)
        return 1
    summary_md = (run_dir / "SUMMARY.md").read_text(encoding="utf-8")
    if "Gatling metrics by phase" not in summary_md:
        print("FAIL: Gatling metrics 표 missing", file=sys.stderr)
        return 1
    if "Total" not in summary_md or "Cnt/s" not in summary_md or "Std Dev" not in summary_md:
        print("FAIL: Gatling report columns missing", file=sys.stderr)
        return 1
    if "### Gatling phase: main_booking" not in summary_md:
        print("FAIL: Gatling phase table missing", file=sys.stderr)
        return 1
    if "| 좌석 점유 | baseline |" not in summary_md or "| 좌석 점유 | candidate |" not in summary_md:
        print("FAIL: same-request slot rows are not adjacent", file=sys.stderr)
        return 1
    if "failure_rate" in summary_md or "| OK |" in summary_md or "| KO |" in summary_md:
        print("FAIL: excluded OK/KO/%KO metrics leaked into SUMMARY", file=sys.stderr)
        return 1
    if "Prometheus metrics by phase" not in summary_md:
        print("FAIL: Prometheus phase tables missing", file=sys.stderr)
        return 1
    if "### Prometheus phase: _iter_total" not in summary_md:
        print("FAIL: Prometheus _iter_total phase table missing", file=sys.stderr)
        return 1
    if "| baseline | 12.02 |" not in summary_md or "| candidate | 15.02 |" not in summary_md:
        print("FAIL: same-phase Prometheus slot rows are not adjacent", file=sys.stderr)
        return 1
    if "_iter_total" not in summary_md or "main_booking" not in summary_md:
        print(f"FAIL: phase 행 누락: {summary_md[:300]}", file=sys.stderr)
        return 1
    if "node_cpu mean" not in summary_md or "node_cpu max" not in summary_md:
        print("FAIL: node_cpu mean/max columns missing", file=sys.stderr)
        return 1
    if "node_memory mean" not in summary_md or "node_memory max" not in summary_md:
        print("FAIL: node_memory mean/max columns missing", file=sys.stderr)
        return 1
    if "phase × slot Prometheus 비교" in summary_md or "phase × slot × Prometheus" in summary_md:
        print("FAIL: old combined Prometheus table should not be generated", file=sys.stderr)
        return 1
    if "128.00 MiB" not in summary_md or "144.00 MiB" not in summary_md or "160.00 MiB" not in summary_md:
        print("FAIL: node_memory unit formatting missing", file=sys.stderr)
        return 1
    if "가설 판정" in summary_md:
        print("FAIL: hypotheses 미정의인데 가설 섹션 생성됨", file=sys.stderr)
        return 1
    if "baseline" not in summary_md or "좌석 점유" not in summary_md:
        print(f"FAIL: slot/request_type 누락: {summary_md[:300]}", file=sys.stderr)
        return 1
    print("PASS: summarize selftest (phase별 Gatling/Prometheus 표 + hypotheses 옵셔널)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="run_dir → SUMMARY.md (phase별 Gatling/Prometheus metrics + hypotheses)")
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
