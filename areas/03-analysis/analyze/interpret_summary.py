#!/usr/bin/env python3
"""Manage the post-run AI interpretation section in SUMMARY.md.

This module intentionally does not call an LLM. Codex reads the manifest,
SUMMARY.md, and raw result files, writes the interpretation text, then uses this
script to insert or replace one managed section.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path
from typing import Any

START_MARKER = "<!-- AI_INTERPRETATION:START -->"
END_MARKER = "<!-- AI_INTERPRETATION:END -->"
DEFAULT_HEADING = "## Purpose-based Interpretation"


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _load_yaml(path: Path) -> dict[str, Any]:
    try:
        import yaml
    except ImportError as exc:
        raise RuntimeError("PyYAML not installed") from exc

    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    return data if isinstance(data, dict) else {}


def _manifest_candidates(run_dir: Path) -> list[Path]:
    manifest_id = run_dir.parent.name
    return [
        run_dir / "manifest.yaml",
        run_dir / "manifest.yml",
        run_dir.parent / "manifest.yaml",
        run_dir.parent / f"{manifest_id}.yaml",
        _repo_root() / "bench" / "manifests" / f"{manifest_id}.yaml",
        _repo_root() / "bench" / "manifests" / f"{manifest_id}.yml",
    ]


def load_manifest_for_run(run_dir: Path) -> tuple[Path | None, dict[str, Any]]:
    for candidate in _manifest_candidates(run_dir):
        if candidate.exists():
            return candidate, _load_yaml(candidate)
    return None, {}


def _run_status(run_dir: Path) -> str:
    markers = [name for name in ("RUNNING", "COMPLETED", "FAILED") if (run_dir / name).exists()]
    if len(markers) == 1:
        return markers[0]
    if not markers:
        return "NO_MARKER"
    return "INVALID_MARKERS:" + ",".join(markers)


def _has_interpretation_section(summary_text: str) -> bool:
    return START_MARKER in summary_text and END_MARKER in summary_text


def build_context(run_dir: Path) -> dict[str, Any]:
    manifest_path, manifest = load_manifest_for_run(run_dir)
    summary_path = run_dir / "SUMMARY.md"
    summary_text = summary_path.read_text(encoding="utf-8") if summary_path.exists() else ""

    context = manifest.get("context", {}) if isinstance(manifest.get("context"), dict) else {}
    queries = []
    for query in manifest.get("queries", []) or []:
        if isinstance(query, dict):
            queries.append({"name": query.get("name"), "unit": query.get("unit")})

    slots = []
    for slot in manifest.get("slots", []) or []:
        if isinstance(slot, dict):
            slots.append(
                {
                    "name": slot.get("name"),
                    "scenario_mode": slot.get("scenario_mode"),
                    "source_branch": slot.get("source_branch"),
                }
            )

    return {
        "run_dir": str(run_dir),
        "status": _run_status(run_dir),
        "summary_path": str(summary_path),
        "summary_exists": summary_path.exists(),
        "interpretation_section_present": _has_interpretation_section(summary_text),
        "manifest_path": str(manifest_path) if manifest_path else None,
        "manifest_id": manifest.get("manifest_id") or run_dir.parent.name,
        "context": context,
        "hypotheses": manifest.get("hypotheses", []) or [],
        "queries": queries,
        "slots": slots,
    }


def _normalize_interpretation(text: str, heading: str) -> str:
    body = text.strip()
    if not body:
        raise ValueError("interpretation text is empty")
    if not body.startswith("#"):
        body = f"{heading}\n\n{body}"
    return f"{START_MARKER}\n{body}\n{END_MARKER}"


def replace_managed_section(summary_text: str, interpretation_text: str, heading: str) -> str:
    block = _normalize_interpretation(interpretation_text, heading)
    start = summary_text.find(START_MARKER)
    end = summary_text.find(END_MARKER)

    if (start == -1) != (end == -1):
        raise ValueError("SUMMARY.md has a partial AI interpretation marker block")

    if start != -1:
        end += len(END_MARKER)
        return summary_text[:start].rstrip() + "\n\n" + block + "\n" + summary_text[end:].lstrip()

    return summary_text.rstrip() + "\n\n" + block + "\n"


def apply_interpretation(
    run_dir: Path,
    interpretation_text: str,
    heading: str = DEFAULT_HEADING,
    allow_failed: bool = False,
    allow_missing_marker: bool = False,
) -> Path:
    summary_path = run_dir / "SUMMARY.md"
    if not summary_path.exists():
        raise FileNotFoundError(f"SUMMARY.md not found: {summary_path}")

    status = _run_status(run_dir)
    if status == "RUNNING":
        raise RuntimeError("run is still RUNNING; wait for COMPLETED or FAILED")
    if status == "FAILED" and not allow_failed:
        raise RuntimeError("run has FAILED marker; pass --allow-failed to annotate a failed run")
    if status not in {"COMPLETED", "FAILED"} and not allow_missing_marker:
        raise RuntimeError(f"run marker is not complete: {status}")

    summary_text = summary_path.read_text(encoding="utf-8")
    out = replace_managed_section(summary_text, interpretation_text, heading)
    tmp = summary_path.with_suffix(".md.tmp")
    tmp.write_text(out, encoding="utf-8")
    tmp.replace(summary_path)
    return summary_path


def _read_interpretation(args: argparse.Namespace) -> str:
    if args.file:
        return Path(args.file).read_text(encoding="utf-8")
    if args.text is not None:
        return args.text
    if args.stdin:
        return sys.stdin.read()
    raise ValueError("provide --file, --text, or --stdin")


def _selftest() -> int:
    with tempfile.TemporaryDirectory(prefix="rtbench-interpret-") as tmp:
        run_dir = Path(tmp) / "bench" / "results" / "interpret-selftest" / "interpret-selftest-20260511-000000"
        run_dir.mkdir(parents=True)
        (run_dir / "COMPLETED").write_text("completed_at=2026-05-11T00:00:00Z\n", encoding="utf-8")
        (run_dir / "manifest.yaml").write_text(
            "\n".join(
                [
                    'manifest_id: "interpret-selftest"',
                    'run_id_prefix: "interpret-selftest"',
                    "context:",
                    '  purpose: "Compare baseline and candidate section switching behavior."',
                    '  comparison_axis: "section switch transport"',
                    '  decision_question: "Is candidate stable enough to prefer?"',
                    "  interpretation_focus:",
                    '    - "section_move latency"',
                    '    - "node_cpu mean/max"',
                    "queries:",
                    '  - name: "node_cpu"',
                    '    unit: "cores"',
                    "slots:",
                    '  - name: "baseline"',
                    '  - name: "candidate"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        (run_dir / "SUMMARY.md").write_text("# SUMMARY - interpret-selftest\n\n## Metrics\n\nbase\n", encoding="utf-8")

        context = build_context(run_dir)
        if context["context"].get("decision_question") != "Is candidate stable enough to prefer?":
            print("FAIL: context extraction failed", file=sys.stderr)
            return 1

        apply_interpretation(run_dir, "Candidate is acceptable for the selftest.")
        once = (run_dir / "SUMMARY.md").read_text(encoding="utf-8")
        if START_MARKER not in once or DEFAULT_HEADING not in once:
            print("FAIL: interpretation section missing", file=sys.stderr)
            return 1

        apply_interpretation(run_dir, "Replacement text.")
        twice = (run_dir / "SUMMARY.md").read_text(encoding="utf-8")
        if twice.count(START_MARKER) != 1 or "Candidate is acceptable" in twice or "Replacement text." not in twice:
            print("FAIL: interpretation replacement is not idempotent", file=sys.stderr)
            return 1

    print("PASS: interpret_summary selftest")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Insert or replace post-run AI interpretation in SUMMARY.md")
    ap.add_argument("run_dir", nargs="?", help="bench/results/<manifest_id>/<run_id>")
    ap.add_argument("--context", action="store_true", help="print manifest/run context as JSON and exit")
    ap.add_argument("--file", help="markdown file containing the AI interpretation body")
    ap.add_argument("--text", help="AI interpretation body")
    ap.add_argument("--stdin", action="store_true", help="read AI interpretation body from stdin")
    ap.add_argument("--heading", default=DEFAULT_HEADING, help="heading used when body has no markdown heading")
    ap.add_argument("--allow-failed", action="store_true", help="allow annotating a FAILED run")
    ap.add_argument("--allow-missing-marker", action="store_true", help="allow annotating a run without a completion marker")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()
    if not args.run_dir:
        ap.print_help()
        return 1

    run_dir = Path(args.run_dir)
    if args.context:
        print(json.dumps(build_context(run_dir), ensure_ascii=False, indent=2))
        return 0

    try:
        interpretation = _read_interpretation(args)
        path = apply_interpretation(
            run_dir,
            interpretation,
            heading=args.heading,
            allow_failed=args.allow_failed,
            allow_missing_marker=args.allow_missing_marker,
        )
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(f"SUMMARY.md interpretation updated: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
