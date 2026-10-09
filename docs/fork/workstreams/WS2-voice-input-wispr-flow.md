# WS2 — Voice I/O (Wispr Flow in, speech out)

**Branch:** `ws/voice-io` · **Runs:** Phase 1, parallel · **Read first:** PRODUCT.md, CONTRACTS.md §6, research/03, upstream `BuddyDictationManager.swift`, `AppleSpeechTranscriptionProvider.swift`, `BuddyAudioConversionSupport.swift`.

## Goal
After a summon, get the user's sentence as text with **zero keyboard use**, transcribed by **Wispr Flow**, then auto-submit. Fall back to on-device Apple Speech when Flow doesn't deliver. Also provide speech output.

## You own (new files only)
- `leanring-buddy/VoiceInputPanel.swift` — borderless, **non-activating, key-capable** `NSPanel` (`canBecomeKey = true`) with one text field, live level meter, hint text; positioned near the cursor on the captured screen
- `leanring-buddy/WisprFlowDriver.swift` — starts/stops Flow by synthesizing its configured trigger (`CGEvent` key chord or other-mouse-button); configurable in UserDefaults
- `leanring-buddy/EndOfSpeechDetector.swift` — `AVAudioEngine` tap, energy VAD, rolling 30 s PCM ring buffer
- `leanring-buddy/VoiceInputCoordinator.swift` — implements `VoiceUtteranceProvider`
- `leanring-buddy/LocalSpokenResponseOutput.swift` — implements `SpokenResponseOutput` with `AVSpeechSynthesizer`; keep upstream ElevenLabs as an alternate implementation behind the same protocol
- tests + `docs/fork/research/05-wispr-flow-spike.md`

Don't edit shared files (see WS1 list). Ask the lead via your report for Info.plist keys if needed.

## Tasks
1. **Spike first (≤ 2 h)** — answer the five questions in research/03 on Ayaan's Mac. Write findings and the chosen trigger + required Flow settings. If something needs Ayaan to change a Flow setting, list it plainly.
2. Implement the flow: show panel (focus field) → start Flow → VAD end-of-speech (≥ 900 ms silence after ≥ 300 ms speech, settings) → stop Flow → wait until the field text is unchanged for 500 ms → return text. Hard cap 30 s of speech.
3. **Fallback:** if no text arrives within 2.5 s after stop (or Flow isn't running: check `NSRunningApplication` by bundle ID), transcribe the ring buffer since summon with Apple Speech on-device and return that. Log which path was used.
4. Focus hygiene: after returning, hide the panel and make sure the previously frontmost app is still frontmost (restore if the panel had to activate).
5. `cancelUtteranceCapture()` stops Flow, hides panel, discards text.
6. Speech output: rate/voice settings; `isSpeaking` published; `stopSpeaking()` immediate (barge-in).

## Acceptance
- 10/10 sample utterances (quiet room) arrive as text and auto-submit without touching keyboard or mouse.
- With Flow quit, the fallback returns usable text.
- Frontmost app unchanged after each run.
- Latency logged: speech end → submit (target ≤ 1.2 s with Flow).

## Report back
Spike results, the exact Flow settings Ayaan must set, files added, manual test steps.
