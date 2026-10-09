# Voice: Wispr Flow input, hands-free summon, speech output

## What Wispr Flow gives us [docs: wisprflow.ai/whats-new, api-docs.wisprflow.ai]

- Flow **types cleaned-up dictation into whatever text field has focus** (filler removal, self-corrections, names). That's the integration surface: give Flow a focused text field and it works with zero API.
- Push-to-talk hotkey; **double-tapping it toggles hands-free mode** (Aug 21 2026). Shortcuts are rebindable; **any non-primary mouse button can trigger dictation** (Mar 31 2026); Escape/Enter keys rebindable.
- Virtual/routed mic inputs supported (Krisp, BlackHole, …).
- May 1 2026: long dictations into Claude Code / Codex no longer collapse into "[Pasted N lines]".
- There is a developer **voice API** (WebSocket `/ws`, REST `/api`, access tokens), but its docs don't say it's included with a consumer subscription → **don't depend on it**.

## Hands-free flow we want

```
"Hey Clicky" ─► capture + dim ─► VoiceInputPanel gets key focus (non-activating NSPanel)
            ─► WisprFlowDriver synthesizes Flow's shortcut (start, hands-free)
            ─► user speaks ─► EndOfSpeechDetector (our own mic tap, VAD) sees ~900 ms silence
            ─► WisprFlowDriver synthesizes stop ─► Flow inserts text into the panel
            ─► text unchanged for 500 ms ─► submit
fallback: if no text 2.5 s after stop → transcribe our rolling mic buffer with Apple Speech (on-device)
```
macOS lets several apps read the microphone at once, so our VAD/ring buffer can run while Flow records.

## Unknowns → WS2 spike (time-box ~2 h, write results to `research/05-wispr-flow-spike.md`)

1. Which Flow trigger can we synthesize reliably? Fn/Globe usually can't be synthesized; try a dedicated chord (e.g. ⌃⌥⌘F18-style) or a **synthesized other-mouse-button** event (`CGEvent` `otherMouseDown` button 3/4) bound in Flow. Check the mouse event doesn't also trigger the app under the cursor.
2. Hands-free mode: start/stop semantics, and whether Flow stops by itself on silence.
3. Insertion method (paste vs keystrokes; streaming vs final) and whether it lands in a **non-activating** panel's text field. If not, try making the panel briefly activating and restore the previous app after submit.
4. Latency from stop → text inserted.
5. Does Flow's own UI/sound appear in our screenshot? (We capture before starting Flow, so it shouldn't matter.)

## Wake word options (WS1 spike)

| Option | Pros | Cons |
|---|---|---|
| Apple Speech on-device keyword spotting (`SFSpeechRecognizer`, `requiresOnDeviceRecognition`; or `SpeechAnalyzer` on macOS 26+) | No dependency, private, already used in repo | Heavier CPU for continuous recognition; session time limits need restart loops; matching "hey clicky" in free text |
| Picovoice Porcupine (custom "Hey Clicky" keyword) | Purpose-built, low CPU, low false accepts | Needs an AccessKey; check current licensing for personal use; C/Swift binding work on macOS |
| openWakeWord (Apache-2.0, ONNX) | Open, trainable custom phrase | Python/ONNX — run as a small sidecar or port to onnxruntime in Swift |

Pick by: false accepts per hour on normal audio (music, calls, YouTube), detection rate at normal speaking distance, idle CPU, and latency. Upstream's paid app limited "Always On" to headphones — **mute or raise the threshold while our TTS is speaking** to avoid self-triggering.

## Speech output

Default to on-device `AVSpeechSynthesizer` (no keys). Keep upstream ElevenLabs client as an option. Expose `SpokenResponseOutput.isSpeaking` so the wake word can pause and the coordinator can fade shapes 2 s after speech ends. Barge-in: a new "Hey Clicky" stops speech immediately.

## Existing STT in the repo [code]
`BuddyTranscriptionProvider.swift` picks AssemblyAI (streaming), OpenAI (upload), or Apple Speech (`AppleSpeechTranscriptionProvider.swift`). Reuse Apple Speech as the no-key fallback.
