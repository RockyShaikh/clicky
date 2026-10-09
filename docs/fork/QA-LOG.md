# QA log

Issues are filed here as a markdown list; baseline numbers are recorded below. Procedures: `TESTING.md`.

## Baseline (raw coordinates)

| Date | Run | Fixtures | Hit rate | p50 | p90 | Notes |
|---|---|---|---|---|---|---|
| 2026-10-08 | `eval-grounding.mjs --selftest` (mock bridge) | 25 synthetic | 80% (20/25, 5 deliberate misses) | 34 ms | 44 ms | Validates scorer only; not a model result |
| pending | live eval against a real session | 25 synthetic | - | - | - | Needs WS3 bridge + a Claude Code session |

Latency: pending real logs (`scripts/latency-report.sh`). Parser verified against `test-fixtures/sample-latency.log`.

## Open issues

- [ ] Live baseline not run yet (bridge and session do not exist on this branch).
- [ ] Fixtures are synthetic mocks; add a handful of real-app screenshots with no personal content once Ayaan can capture them.
- [ ] `--snap` mode not implemented; needs a CLI-callable WS4 snapper.
- [ ] Xcode compile check not run (Xcode.app not installed on this machine).
