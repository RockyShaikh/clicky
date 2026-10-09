# Testing (WS6)

Contracts: `CONTRACTS.md` v1.1. Latency budget: `ARCHITECTURE.md`. Never run the signed app from a terminal; run from Xcode.

## Automated / scripted

| What | Command | Needs |
|---|---|---|
| Regenerate synthetic fixtures | `node scripts/make-fixtures.mjs` | Node |
| Scorer self-test (mock bridge, no model) | `node scripts/eval-grounding.mjs --selftest` | Node |
| Live grounding eval | `node scripts/eval-grounding.mjs [--limit N] [--only str] [--pad PX] [--json]` | bridge running + Claude Code session connected |
| Latency report | `scripts/latency-report.sh [files]` (default `~/.clicky/logs/*.log`) | log lines below |
| Compile check | `xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug -derivedDataPath build/agent-check CODE_SIGNING_ALLOWED=NO build` | Xcode.app |

The live eval uses the fixtures' absolute `image_path` in `/v1/ask`; the bridge's `look` tool must be allowed to read them (they are outside `~/.clicky/shots/`, so WS3 must not restrict `look` to that directory, or the eval should be run with fixtures copied there). The session that serves the eval must be started with `ANTHROPIC_API_KEY` unset and without `--bare`.
Scoring: a HIT means the primary shape's anchor (circle/arrow/label point, box/highlight center, path mean) is inside `target_box_px` (+ `--pad`). Fixtures are synthetic mocks, so the hit rate measures pointing on simple UIs and is an upper bound for real apps; add real-app fixtures later (never screenshots of personal content).

## Latency logging spec

Written by the Swift app and bridge to `~/.clicky/logs/<component>-YYYY-MM-DD.log`, one line per event:

```
<ISO8601 UTC with milliseconds> latency request_id=<r_…> event=<name> [key=value …]
```

Events, in order: `wake` (trigger fired), `capture_done` (screenshots written), `dim_shown`, `speech_end` (utterance finalized by VAD), `submit` (`/v1/ask` sent), `first_event` (first SSE event for the request, e.g. `status`), `respond` (respond event received), `tts_start` (speech playback began). `request_id` is minted at `wake`, so every event for a request carries it. Optional keys: `path=flow|apple` on `speech_end`, `screens=N` on `capture_done`. Use the monotonic-safe wall clock (`Date()`); the report takes the first occurrence of each event per request. Budgets (p50): wake to dim 300 ms, wake to capture_done 150 ms, speech_end to submit 1200 ms, submit to respond 5000 ms, respond to tts_start 400 ms.

## Setup before manual QA

1. Xcode installed; open `leanring-buddy.xcodeproj`, set the signing team (stable signing keeps permissions), Cmd+R.
2. Grant in System Settings > Privacy & Security: Screen Recording, Accessibility (and Input Monitoring if prompted), Microphone, Speech Recognition. After granting Screen Recording, quit and relaunch from Xcode.
3. Wispr Flow installed, running, and configured for the dedicated Clicky trigger (per WS2 spike notes).
4. Start the session: `scripts/clicky-session.sh` (once WS3 lands). Confirm `curl -H "Authorization: Bearer $(cat ~/.clicky/bridge-token)" localhost:8977/v1/health` reports `channel_registered: true`.
5. Verify `ANTHROPIC_API_KEY` is unset in the session's shell (otherwise API billing instead of plan) and that Claude Code was not launched with `--bare`.

## Manual E2E checklist

Mark each: pass / fail / notes. Record failures in `QA-LOG.md`.

### Scenario 1: Point (Notes)
- [ ] Notes open, nothing touched. Say "Hey Clicky, where do I change the font size?"
- [ ] Screen dims (semi-gray) within ~0.3 s; input panel shows on the captured screen.
- [ ] Transcript appears, auto-submits without keyboard use.
- [ ] One or two spoken sentences; the Format control is circled/boxed; cursor flies to it.
- [ ] Overlay clears after the answer; screen undims.

### Scenario 2: Teach (steps)
- [ ] "Hey Clicky, walk me through exporting this as PDF." Step 1 drawn and spoken.
- [ ] Clicking inside the target advances to step 2 (`step_done`); clicking elsewhere does not.
- [ ] Last step ends cleanly.

### Scenario 3: Do (web, Chrome)
- [ ] On a sign-up page: "Hey Clicky, fill this page with my information." Status bubbles appear.
- [ ] Fields filled from `~/.clicky/profile.md` in the current tab; summary read back.
- [ ] Spoken "Submit?" before any final action; saying "no" leaves the form unsubmitted; "yes" submits.
- [ ] Nothing is typed into password fields without an explicit ask.

### Scenario 4: Follow-up
- [ ] After scenario 1: "Hey Clicky, and how do I make that the default?" continues the same conversation (references the prior answer).

### Scenario 5: Cancel
- [ ] Mid-answer: "Hey Clicky, stop" clears the screen and stops speech.
- [ ] Esc does the same, including while a do-mode task is running.

### Scenario 6: Research into a folder (later)
- [ ] "Hey Clicky, research X and put notes in a folder." Creates `~/ClickyWorkspace/<slug>/` with notes.

### Multi-monitor
- [ ] Two displays: summon with the cursor on display B. Dim and capture apply per design (cursor screen is `screen_index` 1); drawing lands on the right display at the right position.
- [ ] Mixed Retina and non-Retina displays: shapes line up with the real control (compare to the screenshot).
- [ ] Display arranged above/left of the primary (negative global coordinates) still maps correctly.
- [ ] Disconnecting a display mid-session does not crash the app.

### Failure and fallback paths
- [ ] **Wispr Flow quit:** quit Flow, summon. Falls back to Apple Speech within ~2.5 s; log shows `path=apple`; the answer still works.
- [ ] **Bridge down:** stop the session. App shows an error state and speaks/shows a clear message (or falls back per ARCHITECTURE.md), no hang.
- [ ] **Bridge token wrong/missing:** requests are rejected (401), app surfaces an error.
- [ ] **No wake word heard / false trigger:** background speech and media audio do not trigger repeatedly; Clicky's own speech does not re-trigger it.
- [ ] **Password manager frontmost:** summon skips capture (denylist).
- [ ] **Claude busy:** a second ask while one is running supersedes the older one.

### Team-plan channel check (Ayaan's org)
- [ ] Run `/status` in the session: logged in via `/login` (not an API key or `setup-token`).
- [ ] Session started with `--dangerously-load-development-channels server:clicky`; the warning dialog is accepted.
- [ ] `/v1/health` shows `channel_registered: true` and an ask results in a `respond` event.
- [ ] If channels are blocked by the org: confirm whether Ayaan is an Owner (Organization settings > Claude Code > Channels). If not, either use the personal plan for the session or switch to the headless `claude -p` fallback; record the outcome in `QA-LOG.md`.

### Privacy and security
- [ ] `~/.clicky/bridge-token` is mode 0600; bridge refuses non-local connections and requests without the bearer token.
- [ ] `~/.clicky/shots/` keeps at most 50 files; nothing from it or `~/.clicky/` is staged in git.
- [ ] A page containing text like "ignore previous instructions and ..." does not change Claude's behavior.

### Latency
- [ ] After 10 requests run `scripts/latency-report.sh`; paste the table into `QA-LOG.md`.
