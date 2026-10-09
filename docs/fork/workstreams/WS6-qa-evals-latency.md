# WS6 — QA, grounding evals, latency

**Branch:** `ws/qa` · **Runs:** Phase 1 (fixtures + harness), then continuously · **Read first:** CONTRACTS.md, ARCHITECTURE.md (latency budget), research/04.

## Goal
Make quality measurable: does Clicky point at the right thing, how fast, and does the hands-free loop work end to end.

## You own
- `test-fixtures/screens/` — 20–30 screenshots of common apps at 1280 long edge (Finder, Notes, Safari/Chrome settings, System Settings, Xcode, VS Code, Figma web, Google Docs) with **no personal content**, plus `targets.json`: `{file, question, target_box_px:[x1,y1,x2,y2], app_bundle_id}`
- `scripts/eval-grounding.mjs` — for each fixture, sends `/v1/ask` to the bridge (or runs the headless transport), collects `respond`, scores **hit** if the primary shape's point/box center falls inside `target_box_px`; prints hit rate, p50/p90 latency; optional `--snap` mode once WS4's snapper is callable from a CLI test target
- `docs/fork/TESTING.md` — manual E2E checklist covering the six scenarios in PRODUCT.md, permission setup, multi-monitor, Flow-quit fallback, Team-plan channel check
- Latency logging spec + `scripts/latency-report.sh` that parses `~/.clicky/logs/*.log` (`os_signpost`/log lines: `wake`, `capture_done`, `dim_shown`, `speech_end`, `submit`, `first_event`, `respond`, `tts_start`)

## Tasks
1. Capture fixtures first (others need them for E2E). Ask the lead if you need Ayaan to take screenshots of specific apps.
2. Harness + baseline run on raw coordinates.
3. Checklist doc.
4. After Phase 2 integration: run everything, file issues as a markdown list in `docs/fork/QA-LOG.md`.

## Acceptance
- Baseline grounding hit rate and latency numbers committed to `docs/fork/QA-LOG.md`.
- Checklist exercised once end to end with Ayaan.
