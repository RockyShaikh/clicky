# Contracts (v1.1)

Every workstream codes against this file. Change it only on `main`, bump the version line, and tell the other agents.
**Contract version: 1.2 (2026-10-08)** — 1.1 corrects §6-§8 against the existing code (see "Existing code facts" in §6). 1.2 adds §9 latency logging and the eval `look` path rule.

## 1. Runtime paths

| Path | Written by | Contents |
|---|---|---|
| `~/.clicky/bridge-token` | bridge (creates if missing, mode 0600) | 64 hex chars |
| `~/.clicky/bridge.json` | bridge on start | `{"port": 8977, "pid": 123, "version": "1.0", "started_at": "ISO8601"}` |
| `~/.clicky/shots/` | Swift app | `<request_id>-s<screen_index>.jpg`; keep last 50 |
| `~/.clicky/profile.md` | Ayaan (template from `scripts/make-profile.sh`) | personal info for do mode; never in repo |
| `~/.clicky/logs/` | Swift app + bridge | latency + error logs |
| `~/ClickyWorkspace/` | `scripts/clicky-session.sh` from `session-template/` | session cwd; Claude may create folders here |

Default bridge port **8977** (override with `CLICKY_BRIDGE_PORT`). `request_id` format: `r_` + 10 lowercase base32 chars.

## 2. Bridge HTTP API (app ⇄ bridge)

All requests: `Authorization: Bearer <token>`, JSON bodies, bind 127.0.0.1 only.

`GET /v1/health` → `200 {"ok": true, "channel_registered": true|false, "version": "1.0"}`
`channel_registered` is true once Claude Code has initialized the MCP connection (best signal we have; notifications are not acknowledged).

`POST /v1/ask` → `202 {"accepted": true}`
```json
{
  "request_id": "r_abcde12345",
  "mode": "auto",                       // "auto" | "point" | "do"
  "utterance": "where do I change the font size",
  "screens": [
    {
      "screen_index": 1,
      "image_path": "/Users/rocky/.clicky/shots/r_abcde12345-s1.jpg",
      "width_px": 1280, "height_px": 831,
      "label": "cursor screen (primary focus)",
      "is_cursor_screen": true
    }
  ],
  "frontmost_app": { "name": "Notes", "bundle_id": "com.apple.Notes", "window_title": "Groceries" },
  "browser_tab": { "url": "https://…", "title": "…" },   // optional, only when Chrome is frontmost
  "sent_at": "2026-10-08T21:14:03.120Z"
}
```

`POST /v1/followup` → `202`
```json
{ "request_id": "r_…", "kind": "confirmation", "answer": "yes", "utterance": "yes go ahead" }
{ "request_id": "r_…", "kind": "step_done", "step_index": 1 }
{ "request_id": "r_…", "kind": "cancel" }
```

`GET /v1/events` → `text/event-stream`. Each message: `event: <type>` + `data: <json>`.

| event | data |
|---|---|
| `hello` | `{"version":"1.0"}` on connect; `heartbeat` every 15 s |
| `status` | `{"request_id","text"}` short progress line for a bubble |
| `respond` | `{"request_id","say","screen_index","shapes":[Shape],"steps":[Step]?, "expect_click":bool, "final":bool}` |
| `confirm` | `{"request_id","question"}` app speaks it, listens for yes/no, posts `/v1/followup` |
| `error` | `{"request_id"?, "message"}` |

## 3. What Claude sees (channel events)

The bridge emits `notifications/claude/channel` with `meta` keys made of letters, digits, underscores only (others are silently dropped):
```
<channel source="clicky" kind="ask" request_id="r_abcde12345" mode="auto" screens="1"
         app="Notes" window_title="Groceries" tab_url="">
where do I change the font size
</channel>
```
Other kinds: `confirmation` (body = answer + utterance), `step_done`, `cancel`.
Events that arrive while Claude is busy are delivered together on its next turn; the instructions tell Claude to handle the newest `ask` and treat older ones as superseded.

## 4. MCP tools exposed by the bridge (Claude ⇄ bridge)

| Tool | Input | Result |
|---|---|---|
| `look` | `{request_id, screen_index?}` | MCP **image** content (the JPEG) + text `"screen 1 of 1, 1280x831 px, origin top-left, cursor screen"` |
| `respond` | `{request_id, say, screen_index?, shapes: Shape[], steps?: Step[], expect_click?: bool, final?: bool}` | `"shown"` |
| `status` | `{request_id, text}` | `"ok"` |
| `confirm` | `{request_id, question}` | `"asked — end your turn and wait for a kind=confirmation event"` |

Permission rule for the session: `mcp__clicky__*` is pre-allowed in `session-template/.claude/settings.json`.

## 5. Shapes (screenshot pixels, origin top-left, of `screen_index`)

```jsonc
{ "kind": "circle",    "x": 1100, "y": 42, "r": 28,                    "label": "color inspector" }
{ "kind": "box",       "x": 900,  "y": 30, "x2": 1180, "y2": 56,       "label": "toolbar" }
{ "kind": "arrow",     "x": 1100, "y": 42, "from_x": 950, "from_y": 160, "label": "" }   // points AT x,y
{ "kind": "label",     "x": 640,  "y": 300, "text": "click here first" }
{ "kind": "path",      "points": [[100,200],[180,205],[260,200]],      "label": "underline" }
{ "kind": "highlight", "x": 200,  "y": 300, "x2": 600, "y2": 340 }    // translucent fill
// optional on every shape:
"snap": true,              // snap to the accessibility element under the point / box center
"emphasis": "primary"      // "primary" (cursor flies here; max 1) | "secondary"
```
`Step = { "say": string, "shapes": Shape[], "expect_click": bool }` — the app shows one step at a time and posts `step_done` when the user clicks inside the primary shape.

Limits: ≤ 6 shapes per respond; `say` ≤ ~2 spoken sentences unless the user asked for detail.

## 6. Swift interfaces (names follow AGENTS.md: long and explicit)

```swift
struct CapturedScreenForRequest: Codable, Equatable {
    let screenIndex: Int
    let imageFileURL: URL
    let imageWidthInPixels: Int
    let imageHeightInPixels: Int
    let displayFrameInAppKitGlobalPoints: CGRect   // NSScreen.frame
    let isCursorScreen: Bool
    let label: String
}

enum CompanionRequestMode: String, Codable { case auto, point, doTask = "do" }

struct CompanionRequest: Codable {
    let requestID: String
    let utteranceText: String
    let mode: CompanionRequestMode
    let capturedScreens: [CapturedScreenForRequest]
    let frontmostApplicationName: String?
    let frontmostApplicationBundleIdentifier: String?
    let frontmostWindowTitle: String?
    let frontmostBrowserTabURL: String?
    let frontmostBrowserTabTitle: String?
}

enum CompanionFollowUp: Codable {
    case confirmation(requestID: String, answerIsYes: Bool, utteranceText: String)
    case stepDone(requestID: String, stepIndex: Int)
    case cancel(requestID: String)
}

enum CompanionEvent {
    case status(requestID: String, text: String)
    case respond(CompanionResponse)
    case confirm(requestID: String, question: String)
    case error(requestID: String?, message: String)
}

struct CompanionResponse: Codable {
    let requestID: String
    let spokenText: String
    let screenIndex: Int
    let annotationShapes: [AnnotationShape]     // WS4 owns AnnotationShape (Codable, matches §5)
    let walkthroughSteps: [WalkthroughStep]?
    let expectsClickOnPrimaryShape: Bool
    let isFinalResponse: Bool
}

protocol BrainTransport: AnyObject {                       // WS3
    var transportDisplayName: String { get }
    func checkAvailability() async -> Bool
    func sendRequest(_ request: CompanionRequest) async throws
    func sendFollowUp(_ followUp: CompanionFollowUp) async throws
    var companionEvents: AsyncStream<CompanionEvent> { get }
    func cancelRequest(requestID: String) async
}

enum SummonTriggerSource { case wakeWord, keyboardShortcut }
protocol SummonTriggerProvider: AnyObject {               // WS1
    var summonTriggers: AsyncStream<SummonTriggerSource> { get }
    func pauseListeningWhileSpeaking(_ isSpeaking: Bool)
}

protocol ScreenCaptureForRequestProvider: AnyObject {     // WS1
    func captureScreensForNewRequest(requestID: String) async throws -> [CapturedScreenForRequest]
}

protocol VoiceUtteranceProvider: AnyObject {              // WS2
    /// Shows the input panel on the captured screen, runs Wispr Flow (or fallback), returns final text.
    func captureUtterance(onScreen capturedScreen: CapturedScreenForRequest?) async throws -> String
    func cancelUtteranceCapture()
}

protocol SpokenResponseOutput: AnyObject {                // WS2
    func speak(_ text: String) async
    func stopSpeaking()
    var isSpeaking: Bool { get }
}
```

### Existing code facts (verified against the repo)

- **Capture today:** `CompanionScreenCaptureUtility` is a `@MainActor enum`; `captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture]`. `CompanionScreenCapture` holds `imageData: Data` (in memory, JPEG q0.8, **no file written**), `label`, `isCursorScreen`, `displayWidthInPoints`/`displayHeightInPoints` (Int), `displayFrame` (`NSScreen.frame`, AppKit bottom-left origin), `screenshotWidthInPixels`/`screenshotHeightInPixels`. Long edge is capped at 1280 px. WS1 writes the files to `~/.clicky/shots/` and maps this struct to `CapturedScreenForRequest` (`imageFileURL`, `isCursorScreen`, etc.).
- **Screen numbering:** displays are sorted with the **cursor screen first**; `screen_index` is 1-based in that order (so with a cursor screen, it is index 1). The capture excludes this app's own windows, so the dim/overlay never appears in screenshots; still capture before showing the dim.
- **Legacy POINT tag:** `[POINT:x,y:label]`, `[POINT:x,y:label:screenN]` or `[POINT:none]`, anchored at the end of the reply, integer pixels in the screenshot space, `screenN` 1-based, label optional (`CompanionManager.parsePointingCoordinates`). It stays as the fallback path for the old Claude-API flow; the channel flow uses `respond` shapes instead.
- **TTS:** `ElevenLabsTTSClient.speakText(_:) async throws` returns as soon as playback **starts** (not when it ends); also `isPlaying: Bool` and `stopPlayback()`. A `SpokenResponseOutput.speak` implementation must therefore wait for playback to finish (poll `isPlaying`) before returning, and `stopSpeaking()` maps to `stopPlayback()`.
- **Transcription:** `BuddyTranscriptionProvider` is a push-to-talk streaming-session protocol (`startStreamingSession(keyterms:onTranscriptUpdate:onFinalTranscriptReady:onError:)` returning a `BuddyStreamingTranscriptionSession`), selected by `BuddyTranscriptionProviderFactory` from the Info.plist key `VoiceTranscriptionProvider` (`assemblyai`|`openai`|`apple`). It is not the `VoiceUtteranceProvider` in this file; WS2 may wrap `apple` as the fallback but must not change the protocol.
- **Planned, not yet in repo:** `session-template/`, `scripts/clicky-session.sh`, `scripts/make-profile.sh` and the bridge (WS3) do not exist yet; `scripts/` currently holds only `release.sh`.

## 7. View mounting (lead only)

WS1 and WS4 ship **standalone SwiftUI views + `@MainActor` observable state**; they do not edit `OverlayWindow.swift`.
- `CaptureDimLayerView(state: CaptureDimLayerState)` — full-screen dim + pill for one screen.
- `AnnotationLayerView(state: AnnotationLayerState)` — draws mapped shapes for one screen.
The overlay today is one `OverlayWindow` (NSPanel) per `NSScreen`, each hosting a `BlueCursorView(screenFrame: screen.frame, …)` whose top-level `ZStack` is where the lead adds both views per screen in Phase 2 (dim under annotations, annotations under the blue cursor).

## 8. Coordinate mapping (WS4 implements, everyone assumes)

Matches the existing logic in `CompanionManager` (clamp, scale to display points, flip Y). `displayFrame` is `NSScreen.frame`, so the result is in the same space as `NSEvent.mouseLocation`; inside a per-screen overlay view, local y = `screenFrame.height − (globalY − screenFrame.origin.y)`.

image px (top-left) → clamp → × (displayFrame.width / imageWidth, displayFrame.height / imageHeight) → flip Y (`displayHeight − y`) → + displayFrame.origin → AppKit global points.
Unit-test example from upstream: (1100, 42) in 1280×831 on a 1512×982 display at origin (0,0) → (1299.4, 932.4).

## 9. Latency logging and evals (WS6 consumes, everyone emits)

The app and bridge write latency lines to `~/.clicky/logs/<component>-YYYY-MM-DD.log` (`component` = `app` or `bridge`), one per event:

```
<ISO8601 UTC with milliseconds> latency request_id=<r_…> event=<name> [key=value …]
```

Events, and who emits each: `wake`, `capture_done` (`screens=N`), `dim_shown` (WS1), `speech_end` (`path=flow|apple`) (WS2), `submit`, `first_event`, `respond` (WS3, app side), `tts_start` (lead/coordinator). `request_id` is minted at `wake` and carried through every later event. Full spec and budgets: `docs/fork/TESTING.md`.

The grounding eval (`scripts/eval-grounding.mjs`) sends `image_path`s under `test-fixtures/screens/`. The bridge must accept image paths under `~/.clicky/shots/` **and** under the repo's `test-fixtures/` directory, or an explicit `CLICKY_EXTRA_IMAGE_DIRS` (colon-separated) env override. All other paths are refused.

