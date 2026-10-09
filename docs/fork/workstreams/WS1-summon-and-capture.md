# WS1 — Summon & capture ("Hey Clicky" + semi-gray screen)

**Branch:** `ws/summon-capture` · **Runs:** Phase 1, parallel · **Read first:** PRODUCT.md, ARCHITECTURE.md, CONTRACTS.md §1, §6, §7; research/03 (wake word), upstream `CompanionScreenCaptureUtility.swift`, `GlobalPushToTalkShortcutMonitor.swift`, `OverlayWindow.swift` (read only).

## Goal
Summon Clicky with no hands: "Hey Clicky" (or a single tap of a hotkey) → capture the cursor screen → dim that screen to semi-gray with a small "Clicky is looking" pill, within 300 ms.

## You own (new files only)
- `leanring-buddy/WakeWordDetector.swift` — implements `SummonTriggerProvider` (CONTRACTS §6)
- `leanring-buddy/SummonKeyboardShortcutMonitor.swift` — single tap of ⌃⌥ = summon (keep upstream hold-to-talk untouched)
- `leanring-buddy/RequestScreenCaptureService.swift` — implements `ScreenCaptureForRequestProvider`; writes `~/.clicky/shots/<request_id>-s<N>.jpg`, long edge 1280, rolling 50 files
- `leanring-buddy/CaptureDimLayerView.swift` + `CaptureDimLayerState` — standalone SwiftUI view (lead mounts it)
- `leanring-buddy/PrivacyCaptureGuard.swift` — skip capture when a password manager / banking app is frontmost (bundle-ID denylist in UserDefaults)
- tests under `leanring-buddyTests/` for your types
- `docs/fork/research/06-wake-word-spike.md` (your spike results)

Do **not** edit `CompanionManager.swift`, `OverlayWindow.swift`, `CompanionPanelView.swift`, `Info.plist`, or `project.pbxproj` (the target uses a synchronized folder; new files are picked up automatically). If you need a shared-file change, describe it in your final report.

## Tasks
1. **Spike (≤ 2 h):** compare the wake-word options in research/03 on false accepts, detection rate, idle CPU, latency. Record numbers and pick one. Phrase: "Hey Clicky". Default threshold conservative.
2. Implement `WakeWordDetector` with the chosen engine; `pauseListeningWhileSpeaking(true)` mutes or raises the threshold while TTS speaks (unless headphones are the output route).
3. `SummonKeyboardShortcutMonitor`: a quick tap of Control+Option (press+release < 250 ms, no other keys) emits `.keyboardShortcut`. Reuse the listen-only `CGEvent` tap pattern.
4. `RequestScreenCaptureService`: capture **cursor screen only** by default (setting `captureAllScreens`); exclude own windows; produce `CapturedScreenForRequest` with exact pixel size and `NSScreen.frame`. Measure capture time.
5. `CaptureDimLayerView`: black at 30% (setting 15–45%), 2 pt accent border, pill near the cursor ("Clicky is looking" → "Listening…" → "Thinking…" from state). Fade in 120 ms (no animation with Reduce Motion). Must never appear in captures: capture completes **before** the state flips to visible.
6. Cancel path: Esc while summoned (only registered while summoned, never global) → emit cancel through state so the lead can wire it.

## Acceptance
- Wake → dim visible ≤ 300 ms p50 on Ayaan's Mac (log timestamps with `os_signpost`, category `latency`).
- 20 consecutive summons: no screenshot contains the dim, pill, or Clicky windows.
- False accepts ≤ 1/hour during 1 h of normal desk audio (target; report actual).
- Idle CPU of the detector reported.
- Unit tests for capture sizing (long edge 1280, aspect kept) and file rotation.

## Report back
What you chose and why (spike numbers), files added, any shared-file changes needed, how to test manually.
