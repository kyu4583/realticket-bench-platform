---
name: realticket-bench-operator
description: Operate the realticket-bench-platform repo as an AI-controlled benchmark conductor. Use when working in this repo to start or resume a benchmark manifest, collect manifest inputs, manage implementation_plan/workflow_state, prepare Gatling or RealTicket benchmark branches, run preflight/run.sh, inspect benchmark results, summarize SUMMARY.md, or check external repo drift. This skill is the Claude Code project entrypoint; repo area docs remain the canonical contracts.
---

# RealTicket Bench Operator

This Claude Code project skill intentionally delegates to the shared Agent Skills source used by Codex:

`.agents/skills/realticket-bench-operator/SKILL.md`

Before acting, read that file and follow it as the operating workflow. Keep canonical platform contracts in `areas/*/README.md`; this skill only selects and applies the workflow.
