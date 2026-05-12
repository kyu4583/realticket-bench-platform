#!/usr/bin/env python3
"""prom_query.py — Prometheus query_range, phase-aware 슬라이싱.

phases.json (run_dir 1개) 가 정의된 단계별로 metric 윈도우를 분리한다.
phases.json 부재 시 phase_markers.jsonl 의 wait marker로 phase 경계를 도출한다.

iter 윈도우는 iter_meta.json 의 iter_start_epoch + (iter_end_epoch | per_run_ms) 로 결정.
매니페스트의 per_run 필드는 더 이상 사용하지 않음 (per_run_ms 는 02-orchestration 이 Plan.json
에서 derive 후 iter_meta 에 기록 — `ceil(plan_max_ms * 1.1)`).

Source: areas/03-analysis/README.md § 분석 모듈 스펙
"""
from __future__ import annotations
import argparse, json, sys
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(__file__).parent / "tests" / "fixtures"


def _parse_wait_ms(s: str) -> int:
    """Parse wait duration string to milliseconds. '50s'→50000, '1m'→60000, '2h'→7200000."""
    s = s.strip()
    if s.endswith("ms"):
        return int(s[:-2])
    if s.endswith("h"):
        return int(s[:-1]) * 3_600_000
    if s.endswith("m"):
        return int(s[:-1]) * 60_000
    if s.endswith("s"):
        return int(s[:-1]) * 1_000
    return int(s) * 1_000  # bare number → seconds


def _parse_region_flow_structure(
    region_flow: object,
) -> tuple[list[list[str]], list[int]]:
    """region_flow list → (groups, waits_ms).

    groups: 연속 step 묶음 목록 (wait 없이 이어진 step들)
    waits:  그룹 사이 wait 시간(ms) 목록
    list 형식이 아니거나 파싱 불가 시 ([], []) 반환.
    """
    if not isinstance(region_flow, list):
        return [], []
    groups: list[list[str]] = []
    waits: list[int] = []
    current_steps: list[str] = []
    for entry in region_flow:
        if not isinstance(entry, dict):
            continue
        if "step" in entry:
            current_steps.append(str(entry["step"]))
        elif "wait" in entry:
            try:
                wait_ms = _parse_wait_ms(str(entry["wait"]))
            except (ValueError, AttributeError):
                continue
            groups.append(current_steps)
            current_steps = []
            waits.append(wait_ms)
    if current_steps:
        groups.append(current_steps)
    return groups, waits


def _marker_phase_boundaries(
    marker_path: Path,
    groups: list[list[str]],
    waits: list[int],
    iter_start: int,
    iter_end: int,
) -> list[dict] | None:
    """phase_markers.jsonl 의 wait_enter marker에서 phase 경계를 도출한다.

    각 wait marker 그룹에서 entryOrder 기준 중간 유저를 고르고,
    그 유저의 wait 진입 시각 + waitMs/2 를 phase 경계로 삼는다.
    """
    if not groups or not waits or len(groups) != len(waits) + 1 or not marker_path.exists():
        return None

    marker_groups: dict[str, list[tuple[int, int, int]]] = {}
    marker_names: list[str] = []
    try:
        with marker_path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    marker = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if marker.get("type") != "wait_enter":
                    continue
                name = str(marker.get("name") or "")
                if not name:
                    continue
                try:
                    entry_order = int(marker.get("entryOrder"))
                    epoch_ms = int(marker.get("epochMs"))
                    wait_ms = int(marker.get("waitMs"))
                except (TypeError, ValueError):
                    continue
                if wait_ms <= 0:
                    continue
                if name not in marker_groups:
                    marker_groups[name] = []
                    marker_names.append(name)
                marker_groups[name].append((entry_order, epoch_ms, wait_ms))
    except OSError:
        return None

    if len(marker_names) < len(waits):
        return None

    boundaries: list[int] = []
    search_from = 0
    for wait_ms in waits:
        chosen_events: list[tuple[int, int, int]] | None = None
        for i in range(search_from, len(marker_names)):
            events = sorted(marker_groups[marker_names[i]], key=lambda e: (e[0], e[1]))
            median_wait_ms = events[(len(events) - 1) // 2][2]
            tolerance_ms = max(1000, int(wait_ms * 0.2))
            if abs(median_wait_ms - wait_ms) <= tolerance_ms:
                chosen_events = events
                search_from = i + 1
                break
        if chosen_events is None:
            return None

        _, epoch_ms, marker_wait_ms = chosen_events[(len(chosen_events) - 1) // 2]
        boundary_epoch = int((epoch_ms + marker_wait_ms / 2) / 1000)
        if not (iter_start < boundary_epoch < iter_end):
            return None
        if boundaries and boundary_epoch <= boundaries[-1]:
            return None
        boundaries.append(boundary_epoch)

    phases: list[dict] = []
    for i, group_steps in enumerate(groups):
        s_epoch = iter_start if i == 0 else boundaries[i - 1]
        e_epoch = iter_end   if i == len(groups) - 1 else boundaries[i]
        phases.append({
            "name": " + ".join(group_steps),
            "start_ms": (s_epoch - iter_start) * 1000,
            "end_ms":   (e_epoch - iter_start) * 1000,
        })
    return phases


def _load_phases(iter_dir: Path) -> list[dict]:
    """phases.json 을 run_dir(=iter_dir.parent) 또는 iter_dir 자체에서 로드.

    production: run_dir/phases.json 이 단일 진실 (run 내 모든 iter 공유).
    test: iter_dir/phases.json 도 fallback 으로 허용 (selftest 편의).
    파일 부재 또는 파싱 실패 시 [] 반환 → 호출자가 _iter_total 만 슬라이싱.
    """
    for candidate in (iter_dir.parent / "phases.json", iter_dir / "phases.json"):
        if candidate.exists():
            try:
                with candidate.open("r", encoding="utf-8") as f:
                    d = json.load(f)
                phases = d.get("phases", []) or []
                # 최소 검증: list[dict] with name/start_ms/end_ms
                clean = []
                for p in phases:
                    if not isinstance(p, dict):
                        continue
                    if "name" not in p or "start_ms" not in p or "end_ms" not in p:
                        continue
                    clean.append(p)
                return clean
            except Exception:
                continue
    return []


def _series_matches_slot(series: dict, slot: str | None) -> bool:
    if not slot:
        return False
    slot = slot.strip().lower()
    if not slot:
        return False
    metric = series.get("metric", {})
    if not isinstance(metric, dict):
        return False

    # RealTicket slot labels appear as e.g. nest-baseline, realticket_nest-baseline,
    # or realticket_nest-baseline.1.<task>. Keep the match tied to the slot suffix
    # to avoid accidentally matching unrelated label text.
    needles = (f"nest-{slot}", f"nest_{slot}", f"-{slot}", f"_{slot}")
    for value in metric.values():
        text = str(value).lower()
        if any(needle in text for needle in needles):
            return True
    return False


def _series_for_slot(resp: dict, slot: str | None) -> list[dict]:
    series = resp.get("data", {}).get("result", [])
    if not isinstance(series, list):
        return []
    if not slot:
        return series
    matching = [s for s in series if _series_matches_slot(s, slot)]
    return matching if matching else series


def _slice_window(resp: dict, start_epoch: int, end_epoch: int,
                   end_inclusive: bool = True, slot: str | None = None) -> dict:
    """Prometheus 응답에서 [start_epoch, end_epoch] (또는 end exclusive) 윈도우 집계."""
    if resp.get("status") != "success":
        return {"mean": None, "max": None, "count": 0, "error": "prom status != success"}
    values: list[float] = []
    for series in _series_for_slot(resp, slot):
        for ts_str, val_str in series.get("values", []):
            try:
                ts = int(ts_str)
            except (TypeError, ValueError):
                continue
            in_window = (start_epoch <= ts <= end_epoch) if end_inclusive else (start_epoch <= ts < end_epoch)
            if in_window:
                try:
                    values.append(float(val_str))
                except (TypeError, ValueError):
                    pass
    if values:
        return {
            "mean": sum(values) / len(values),
            "max": max(values),
            "count": len(values),
        }
    return {"mean": None, "max": None, "count": 0, "error": "no samples in window"}


def query_iter_metrics(iter_dir: str, manifest_path: str,
                        offline_response: dict | None = None,
                        phases_override: list[dict] | None = None) -> dict[str, Any]:
    """iter 윈도우 + phase 별 윈도우로 Prometheus 쿼리 슬라이싱.

    출력 구조:
      {
        "<query_name>": {
          "_iter_total":    {"mean": ..., "max": ..., "count": ...},
          "<phase_name_1>": {"mean": ..., "max": ..., "count": ...},
          ...
        },
        ...
      }
    phases.json 부재 시 phase_markers.jsonl 로 phase를 도출한다.
    출력은 {iter_dir}/prom_metrics.json 에 atomic write.

    offline_response: self-test 모드 — Prometheus HTTP 호출 없이 fixture json 사용.
    phases_override: phases.json 로드 우회 (테스트용).
    """
    try:
        import yaml
    except ImportError:
        return {"error": "PyYAML not installed (pip install -r requirements.txt)"}

    manifest_p = Path(manifest_path)
    if not manifest_p.exists():
        return {"error": f"manifest not found: {manifest_path}"}
    with manifest_p.open("r", encoding="utf-8") as f:
        manifest = yaml.safe_load(f)
    queries = manifest.get("queries", [])

    iter_dir_p = Path(iter_dir)
    iter_meta_p = iter_dir_p / "iter_meta.json"
    if not iter_meta_p.exists():
        return {"error": f"iter_meta.json not found in {iter_dir}"}
    with iter_meta_p.open("r", encoding="utf-8") as f:
        iter_meta = json.load(f)

    iter_start = iter_meta["iter_start_epoch"]
    iter_dir_parts = iter_dir_p.name.split("-", 2)
    iter_slot = str(iter_meta.get("slot") or (iter_dir_parts[2] if len(iter_dir_parts) >= 3 else ""))
    # iter_end 우선순위: iter_end_epoch (실측) → iter_start + per_run_ms/1000 (도출)
    if "iter_end_epoch" in iter_meta:
        iter_end = iter_meta["iter_end_epoch"]
    elif "per_run_ms" in iter_meta:
        iter_end = iter_start + iter_meta["per_run_ms"] // 1000
    else:
        return {"error": "iter_meta.json 에 iter_end_epoch 또는 per_run_ms 필요"}

    if phases_override is not None:
        phases = phases_override
    else:
        phases = _load_phases(iter_dir_p)

    # phases.json 없으면 region_flow 구조와 wait marker를 매칭해 phase 경계를 도출한다.
    if not phases:
        region_flow = (manifest.get("context") or {}).get("region_flow") or []
        if region_flow:
            groups, waits = _parse_region_flow_structure(region_flow)
            phases = _marker_phase_boundaries(
                iter_dir_p / "phase_markers.jsonl",
                groups, waits, iter_start, iter_end,
            ) or []

    out: dict[str, Any] = {}
    for q in queries:
        q_name = q["name"]
        if offline_response is not None:
            resp = offline_response
        else:
            prom_file = iter_dir_p / f"prom_{q_name}.json"
            if not prom_file.exists():
                out[q_name] = {"_iter_total": {"error": f"prom_{q_name}.json not found", "mean": None, "max": None, "count": 0}}
                continue
            raw = prom_file.read_text(encoding="utf-8").strip()
            if raw == "-":
                out[q_name] = {"_iter_total": {"error": "collect_prometheus recorded -", "mean": None, "max": None, "count": 0}}
                continue
            try:
                resp = json.loads(raw)
            except json.JSONDecodeError as e:
                out[q_name] = {"_iter_total": {"error": f"JSON parse error: {e}", "mean": None, "max": None, "count": 0}}
                continue

        per_phase: dict[str, Any] = {
            "_iter_total": _slice_window(resp, iter_start, iter_end, end_inclusive=True, slot=iter_slot)
        }
        for ph in phases:
            try:
                ph_name = str(ph["name"])
                ph_start = iter_start + int(ph["start_ms"]) // 1000
                ph_end = iter_start + int(ph["end_ms"]) // 1000
            except (KeyError, TypeError, ValueError) as e:
                continue
            per_phase[ph_name] = _slice_window(resp, ph_start, ph_end, end_inclusive=False, slot=iter_slot)

        out[q_name] = per_phase

    # Atomic write — prom_metrics.json
    out_path = iter_dir_p / "prom_metrics.json"
    tmp = out_path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    tmp.replace(out_path)
    return out


def _selftest() -> int:
    """phase-aware 슬라이싱 selftest.

    selftest 시나리오:
      - run_dir: FIXTURES_DIR / "selftest_prom"
      - phases.json: 3 phases (auth_check, subscribe, main_booking)
      - iter dir: iter-1-baseline (iter_meta + offline prom_response)
      - 검증: _iter_total + 3 phase 모두 dict, count >= 0
    """
    manifest = FIXTURES_DIR / "manifest.yaml"
    prom_resp = FIXTURES_DIR / "prom_response.json"
    if not (manifest.exists() and prom_resp.exists()):
        print("FAIL: fixtures missing", file=sys.stderr)
        return 1
    with prom_resp.open("r", encoding="utf-8") as f:
        offline = json.load(f)

    # selftest run_dir 합성
    run_dir = FIXTURES_DIR / "selftest_prom"
    run_dir.mkdir(exist_ok=True)
    iter_dir = run_dir / "iter-1-baseline"
    iter_dir.mkdir(exist_ok=True)

    # phases.json (run_dir 레벨)
    phases_doc = {
        "phases": [
            {"name": "auth_check",   "start_ms": 0,     "end_ms": 15000},
            {"name": "subscribe",    "start_ms": 15000, "end_ms": 30000},
            {"name": "main_booking", "start_ms": 30000, "end_ms": 60000},
        ]
    }
    (run_dir / "phases.json").write_text(json.dumps(phases_doc), encoding="utf-8")

    # iter_meta.json (iter dir) — iter_end_epoch + per_run_ms 포함 (per_run 매니페스트 필드 폐기 후)
    iter_meta = {
        "iter": 1,
        "slot": "baseline",
        "iter_start_epoch": 1777663801,
        "iter_end_epoch":   1777663861,
        "per_run_ms":       60000,
    }
    (iter_dir / "iter_meta.json").write_text(json.dumps(iter_meta), encoding="utf-8")

    result = query_iter_metrics(str(iter_dir), str(manifest), offline_response=offline)

    if "error" in result:
        print(f"FAIL: query_iter_metrics error: {result['error']}", file=sys.stderr)
        return 1
    if "http_request_rate" not in result:
        print(f"FAIL: query name missing in result: {result}", file=sys.stderr)
        return 1
    metric = result["http_request_rate"]
    if "_iter_total" not in metric:
        print(f"FAIL: _iter_total missing: {metric}", file=sys.stderr)
        return 1
    if metric["_iter_total"].get("count", 0) < 1:
        print(f"FAIL: _iter_total count = 0: {metric['_iter_total']}", file=sys.stderr)
        return 1
    expected_phases = {"auth_check", "subscribe", "main_booking"}
    missing = expected_phases - set(metric.keys())
    if missing:
        print(f"FAIL: phase 슬라이싱 누락: {missing}", file=sys.stderr)
        return 1
    marker_dir = run_dir / "iter-marker-baseline"
    marker_dir.mkdir(exist_ok=True)
    marker_path = marker_dir / "phase_markers.jsonl"
    marker_lines = [
        {"type": "wait_enter", "name": "test_wait", "entryOrder": 1, "userNum": 1, "epochMs": 1777663810000, "waitMs": 20000},
        {"type": "wait_enter", "name": "test_wait", "entryOrder": 2, "userNum": 2, "epochMs": 1777663820000, "waitMs": 20000},
        {"type": "wait_enter", "name": "test_wait", "entryOrder": 3, "userNum": 3, "epochMs": 1777663830000, "waitMs": 20000},
    ]
    marker_path.write_text("\n".join(json.dumps(line) for line in marker_lines) + "\n", encoding="utf-8")
    marker_phases = _marker_phase_boundaries(
        marker_path,
        [["auth_check"], ["subscribe"]],
        [20000],
        1777663801,
        1777663861,
    )
    if not marker_phases or marker_phases[0].get("end_ms") != 29000:
        print(f"FAIL: marker phase boundary mismatch: {marker_phases}", file=sys.stderr)
        return 1
    slot_filter_resp = {
        "status": "success",
        "data": {
            "result": [
                {
                    "metric": {"job": "nest-baseline", "name": "realticket_nest-baseline.1.abc"},
                    "values": [[1777663801, "1.0"], [1777663802, "1.0"]],
                },
                {
                    "metric": {"job": "nest-candidate", "name": "realticket_nest-candidate.1.def"},
                    "values": [[1777663801, "9.0"], [1777663802, "9.0"]],
                },
            ]
        },
    }
    slot_filtered = _slice_window(slot_filter_resp, 1777663801, 1777663802, slot="baseline")
    if slot_filtered.get("mean") != 1.0 or slot_filtered.get("count") != 2:
        print(f"FAIL: slot series filtering mismatch: {slot_filtered}", file=sys.stderr)
        return 1
    try:
        marker_path.unlink(missing_ok=True)
        marker_dir.rmdir()
    except OSError:
        pass
    # prom_metrics.json 파일 존재 검증
    if not (iter_dir / "prom_metrics.json").exists():
        print("FAIL: prom_metrics.json 미작성", file=sys.stderr)
        return 1
    print(f"PASS: prom_query selftest (_iter_total count={metric['_iter_total']['count']}, "
          f"phases={sorted(expected_phases)})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Prometheus query_range, phase-aware 슬라이싱")
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
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
