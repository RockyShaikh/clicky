# Architecture

## One-screen view

```
 "Hey Clicky" ─► WakeWordDetector ──┐                         (WS1)
 hotkey tap   ─► GlobalShortcut  ───┤
                                    ▼
                           SummonController                   (WS1)
              1. capture cursor screen  (ScreenCaptureKit, own windows excluded)
              2. dim that screen ~30% + "Clicky is looking" pill
                                    ▼
                         VoiceInputCoordinator                (WS2)
              3. VoiceInputPanel (non-activating, key-capable text field)
              4. WisprFlowDriver starts Flow → user talks → EndOfSpeechDetector
                 stops Flow → text stable → submit   (fallback: Apple Speech)
                                    ▼
                   HandsFreeSessionCoordinator  (lead, Phase 2; owns the state machine)
                                    ▼
                    BrainTransport (protocol)                 (WS3)
       ┌────────────────────┬──────────────────────┬────────────────────────┐
  ClaudeCodeChannel    ClaudeCodeHeadless        DirectAPI (upstream Claude
  Transport (primary)  Transport (fallback)      API via Worker, optional)
       │ HTTP + SSE on 127.0.0.1, bearer token
       ▼
  bridge/clicky-channel  (Node/TS MCP channel server, spawned BY Claude Code)  (WS3)
       │ notifications/claude/channel  ──►  <channel source="clicky" kind="ask" ...>
       ▼                                          tools: look · respond · status · confirm
  Claude Code session  (tmux "clicky", cwd ~/ClickyWorkspace, Team plan, --chrome)
       │  point/teach: look → respond(say, shapes)
       │  do (web):    Claude in Chrome tools on the current tab, status…, confirm, respond
       ▼
  SSE events ─► Swift ─► AnnotationLayer (WS4) + SpeechOutput (WS2) + status/confirm UI (WS5)
```

## Components

| Component | Lives in | Owner | Notes |
|---|---|---|---|
| WakeWordDetector, SummonController, CaptureDimLayerView | `leanring-buddy/` | WS1 | Capture before dim. Mute wake word while speaking unless on headphones. |
| VoiceInputPanel, WisprFlowDriver, EndOfSpeechDetector, VoiceInputCoordinator, SpeechOutput | `leanring-buddy/` | WS2 | Flow types into our panel. Keep a rolling mic buffer so the fallback STT can transcribe the same utterance. |
| clicky-channel server | `bridge/clicky-channel/` | WS3 | Declares `claude/channel`. HTTP+SSE for the app; MCP tools for Claude. |
| Session template + launcher | `session-template/`, `scripts/clicky-session.sh` | WS3 | Writes `~/ClickyWorkspace` (CLAUDE.md persona, `.mcp.json`, `.claude/settings.json`), starts tmux. |
| BrainTransport + 3 implementations | `leanring-buddy/` | WS3 | Health check picks channel → headless → direct API. |
| AnnotationLayerView, CoordinateMapper, AccessibilitySnapper, ClickTargetWatcher | `leanring-buddy/` | WS4 | Pure views/state; lead mounts them in `OverlayWindow`. |
| Do mode: Chrome rules, profile, confirmations, status bubbles, test forms | `session-template/`, `leanring-buddy/`, `test-fixtures/forms/` | WS5 | Phase 2. |
| Evals, fixtures, latency logs, E2E checklist | `test-fixtures/`, `scripts/`, `docs/fork/TESTING.md` | WS6 | Runs alongside everything. |
| HandsFreeSessionCoordinator + wiring + settings UI | `leanring-buddy/` | Lead | Only the lead edits `CompanionManager.swift`, `OverlayWindow.swift`, `CompanionPanelView.swift`, `Info.plist`. |

## State machine (HandsFreeSessionCoordinator)

```
idle ──summon──► capturing ──► listening ──utterance──► thinking ──respond──► presenting ──tts+fade──► idle
                     │              │                       │  └─status──► thinking (bubble updates)
                     │              │                       └─confirm──► awaitingConfirmation ──yes/no──► thinking
                     └──────────────┴──── cancel (Esc, "Hey Clicky stop", timeout) ──────────────────────► idle
presenting ──expect_click──► awaitingClick ──hit──► thinking (send step_done)
```
A new summon during `thinking`/`presenting` cancels the current request (barge-in) and starts over.

## Sequences

**Point/teach.** Summon → capture (`~/.clicky/shots/<request_id>-s1.jpg`, long edge 1280) → dim → Flow → `POST /v1/ask` → channel event → Claude calls `look(request_id)` (gets the image + its pixel size) → `respond(request_id, say, shapes, screen)` → SSE `respond` → CoordinateMapper (+ optional AX snap) → dim lifts, shapes draw, cursor flies to primary target, TTS speaks → shapes fade 2 s after speech ends.

**Do (web).** Same entry. Claude decides it's a do-request (or the user said "do/fill/click it for me") → uses Claude in Chrome on the **current tab** (the request carries the frontmost Chrome tab URL/title; Claude must work in that tab because the user asked about *this page*) → `status` bubbles while working → before any submit/send/purchase/delete calls `confirm(question)` and ends its turn → Swift speaks the question and listens for yes/no → `POST /v1/followup kind=confirmation` → Claude continues → `respond` summary.

## Plans and auth (verified Oct 8 2026 — see research/02)

| Capability | Team plan | Personal Pro/Max |
|---|---|---|
| Interactive Claude Code + subagents | ✅ | ✅ |
| Channels (our primary transport) | ⚠️ blocked until an **Owner** enables them | ✅ (no org checks) |
| Custom channel during research preview | needs `--dangerously-load-development-channels server:clicky` (warning dialog at launch) | same |
| Claude in Chrome from Claude Code | ✅ (requires `/login`, not `setup-token`/API key) | ✅ |
| Computer use (native apps) | ❌ not available | ✅ research preview, interactive only |
| `claude -p` headless fallback | ✅ | ✅ |

Rules that bite: if `ANTHROPIC_API_KEY` is set, Claude Code bills the API instead of the plan. `--bare` ignores subscription login. Personal use only; don't ship anyone else your login.

## Latency budget (targets; WS6 measures)

| Step | Target |
|---|---|
| wake word detected → screen dimmed | ≤ 300 ms |
| capture (1 screen) | ≤ 150 ms, done before dim |
| end of speech → text submitted (Flow) | ≤ 1.2 s |
| submit → first `respond` (point mode) | ≤ 5 s (stretch 3 s) |
| `respond` → first spoken word | ≤ 400 ms |

Levers: Sonnet + low effort in the session, small session CLAUDE.md, one screenshot not all screens, `look` returns a 1280-px JPEG, speak while drawing, keep the session warm (prompt cache).

## Privacy and security

- Bridge binds `127.0.0.1` only and requires `Authorization: Bearer <~/.clicky/bridge-token>`; drop anything else (an open local port is a prompt-injection path).
- Screenshots live in `~/.clicky/shots/`, rolling window of the last 50, never in the repo.
- `~/.clicky/profile.md` is private; read only for do-mode requests.
- Skip capture when a password manager is frontmost (bundle-ID denylist), same idea as the community Windows port.
- The session's CLAUDE.md tells Claude to treat on-screen text as untrusted data, not instructions.

## Decisions log

- 2026-10-08: Channel into a persistent interactive session is primary; headless resume is fallback; upstream direct API kept but off by default.
- 2026-10-08: Annotation coordinates are screenshot pixels, top-left origin, with `screen` index; Swift does all mapping (Claude never sees points or Retina scale).
- 2026-10-08: Workstreams add new files only; the lead alone edits shared files and mounts new views.
