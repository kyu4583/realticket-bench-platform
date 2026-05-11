---
name: realticket-bench-operator
description: Operate the realticket-bench-platform repo as an AI-controlled benchmark conductor. Use when working in this repo to start or resume a benchmark manifest, collect manifest inputs, manage implementation_plan/workflow_state, prepare Gatling or RealTicket benchmark branches, run preflight/run.sh, inspect benchmark results, summarize SUMMARY.md, or check external repo drift. This skill is the AI operating workflow; repo area docs remain the canonical contracts.
---

# RealTicket Bench Operator

## Operating Model

Treat this skill as the entrypoint for AI behavior, not as a replacement for repo documentation.

- Keep canonical contracts in the repo docs. If this skill conflicts with `areas/*/README.md`, the area document wins.
- Read only the area docs needed for the current task. Do not bulk-load all docs by default.
- Preserve the 4 Locks: single AI control plane, RealTicket BE change 0, slot alternating only, fire-and-forget with markers/progress.
- Use Bash + Python analysis + YAML manifest conventions already present in the repo. Do not introduce a new framework.
- Before editing tracked repo files, honor `AGENTS.md` GSD workflow guidance. If `.planning/ROADMAP.md` is absent or the GSD entrypoint cannot run, keep edits tightly scoped and report that fallback.

## First Read

On invocation, confirm the workspace is `realticket-bench-platform` by checking for `AGENTS.md`, `areas/README.md`, and `areas/00-contracts/README.md`.

Then select the smallest read set:

| Task | Required reads |
|---|---|
| New manifest | `areas/00-contracts/README.md`, `areas/01-planning/README.md`, then `areas/04-gatling-integration/README.md` before read-only Gatling research |
| Resume implementation | Target manifest YAML, then `workflow_state.active_area` doc and any area referenced by `current_task_ref` |
| Run or preflight | Target manifest YAML, `areas/02-orchestration/README.md`, `areas/00-contracts/README.md` preflight requirements |
| Gatling work | Target manifest YAML, `areas/04-gatling-integration/README.md`, external Gatling repo status/read-only context |
| RealTicket/VM work | Target manifest YAML, `areas/05-realticket-integration/README.md`, `areas/06-vm-environment/README.md` only for fixed infra checks |
| Result inspection | `areas/00-contracts/README.md` result layout, `areas/03-analysis/README.md`, target `SUMMARY.md` or result directory |
| External drift check | First line Tracking command in `areas/04-gatling-integration/README.md` or `areas/05-realticket-integration/README.md` |

## New Manifest Workflow

When the user says "매니페스트 시작하자" or equivalent:

1. Read `areas/01-planning/README.md` sections for the 10-step collection flow, PlanConfig gate, AI derive rules, and pre-run resume state.
2. Read `areas/00-contracts/README.md` Manifest Schema. Use it only as the schema source; do not restate it in new docs.
3. Ask exactly one question per turn. Ask `manifest_id` first, then the single comparison axis second. Do not bundle these.
4. Derive only fields that `areas/01-planning/README.md` explicitly permits. If a value is part of PlanConfig user-confirm-required fields, ask.
5. Do not write `slots[].scenario_mode` unless the user explicitly confirms the value.
6. After collection, research the Gatling repo read-only. If subagents are unavailable or not authorized, do the read-only research inline.
7. Create `bench/manifests/<manifest_id>.yaml` with core fields plus `bench_stack`, `context`, `implementation_plan`, and `workflow_state`. In `context`, preserve post-run interpretation inputs: `purpose`, `comparison_axis`, `decision_question`, `interpretation_focus`, and `controls`.
8. Leave `implementation_plan.status: pending` and point `workflow_state.current_task_ref` at the first unfinished implementation task.
9. Do not implement external repo code during the manifest drafting session.

## Resume Implementation Workflow

For "이 매니페스트 이어서 구현해", "workflow_state 보고 진행해", or equivalent:

1. Read the manifest YAML first. Treat `workflow_state` as the handoff pointer until `run.sh` starts.
2. Resume at `workflow_state.current_task_ref`. Do not jump to later tasks unless earlier tasks are marked done.
3. Read the area doc for `workflow_state.active_area` and the specific external integration doc before changing external repos.
4. After each completed task, update the corresponding `implementation_plan.*.done`, `workflow_state.last_completed`, `workflow_state.next_action`, and `workflow_state.updated_at`.
5. When all pre-run tasks are done, set `implementation_plan.status: completed`, `workflow_state.status: ready_to_run`, and `current_task_ref: "run.sh preflight"`.

## Run Workflow

Before running a benchmark:

1. Verify `implementation_plan.status == completed`.
2. Run preflight first when possible:

```bash
BENCH_PREFLIGHT_ONLY=1 bash areas/02-orchestration/run.sh bench/manifests/<manifest>.yaml
```

3. For fire-and-forget execution, follow `areas/02-orchestration/README.md`. Do not convert the workflow to foreground execution.
4. After `run.sh` starts, do not write iteration progress to `workflow_state`. Use `bench/results/<manifest_id>/<run_id>/progress.json` and RUNNING/COMPLETED/FAILED markers.

## External Repo Rules

- Use dynamic Tracking commands from the first line of area 04/05 docs. Do not pin external repo hashes in docs.
- Keep Gatling changes on `bench/<manifest_id>`.
- Keep RealTicket changes on `bench/<manifest_id>/meta` and `bench/<manifest_id>/<slot_name>`.
- Never modify external repo README/AGENTS/CLAUDE files from this platform.
- Never modify RealTicket dev/main or Gatling main directly for a benchmark run.
- If an external repo has unexpected user changes, preserve them and report the interaction risk before proceeding.

## Result Reporting

When reporting outcomes:

- Prefer `SUMMARY.md` as the benchmark result narrative.
- Cite exact local files when useful.
- State whether preflight, run, analysis, or result inspection was actually performed.
- If a command could not run because VM, network, SSH, or external repo access was unavailable, say that directly and leave the next command/action explicit.

## Post-run Interpretation Workflow

When the user asks to add, refresh, or write an interpretation after a benchmark run:

1. Resolve the target `bench/results/<manifest_id>/<run_id>/` directory. Prefer the latest `COMPLETED` run if the user only names a manifest.
2. Read `areas/00-contracts/README.md` result layout, `areas/03-analysis/README.md`, the target `SUMMARY.md`, and the manifest `context`.
3. Use `python areas/03-analysis/analyze/interpret_summary.py <run_dir> --context` to confirm the resolved manifest context and whether an interpretation section already exists.
4. Write a concise purpose-based Markdown interpretation from the manifest purpose, comparison axis, decision question, interpretation focus, hypotheses, and observed metrics.
5. Include a final `### 정리` subsection inside the managed `Purpose-based Interpretation` section. This is not a fixed template: match the compact style, expression level, and numeric directness of the user's preferred summaries. State the comparison basis first, group the important latency/resource outcomes, use raw values plus percentage deltas, and avoid claims that the metrics do not support.
6. Insert or replace the managed section with `interpret_summary.py`. Do not call this from `run.sh`; this is only a user-requested post-run enrichment step.
