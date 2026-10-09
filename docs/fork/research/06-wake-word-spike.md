# 06 - Wake word spike ("Hey Clicky")

Status: **decision made without measurements.** The spike needs Ayaan's voice and mic, so no false-accept, detection-rate, CPU or latency numbers exist yet. The table below is blank on purpose; fill it using the harness.

## Decision

Ship **Apple on-device `SFSpeechRecognizer`** (`WakeWordDetector.swift`) as the default engine.

Why: zero dependencies and no AccessKey, private (`requiresOnDeviceRecognition`), already authorised in the app for Apple Speech, and the phrase is matched in code, so changing it needs no model training. Known costs: continuous recognition uses more CPU than a purpose-built detector, tasks must be restarted (done every 50 s), and false accepts depend on text matching rather than an acoustic model. The matcher therefore requires a greeting word right before "clicky" (`hey/hi/hay clicky`, plus split forms like "click e"); the bare word "clicky" does not trigger. A 2 s cooldown applies between triggers.

Fallback if the numbers below fail (CPU > ~10% idle or > 1 false accept/hour): **Picovoice Porcupine** with a custom "Hey Clicky" keyword (needs a free AccessKey, check personal-use licensing). `WakeWordDetector` already hides the engine behind `SummonTriggerProvider`, so the swap is local to that file. openWakeWord was not chosen: it needs a Python/ONNX sidecar or an onnxruntime port.

## Results (to fill in)

| Metric | Target | Apple Speech | Porcupine (only if needed) |
|---|---|---|---|
| False accepts in 1 h of desk audio | <= 1 | ? | ? |
| Detection rate, 20 utterances at ~1 m | >= 90% | ? | ? |
| Idle CPU of the harness process | report | ? | ? |
| Phrase end to trigger latency | report | ? | ? |

## Manual steps for Ayaan (about 15 min plus a 1 h soak)

1. From the worktree root build the harness (compile only, not the app):
   ```
   xcrun swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.2 -swift-version 5 \
     -default-isolation MainActor -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
     -Xlinker docs/fork/research/06-wake-word-harness/Info.plist -o build/harness/wake-word-harness \
     docs/fork/research/06-wake-word-harness/main.swift leanring-buddy/WakeWordDetector.swift \
     leanring-buddy/RequestScreenCaptureService.swift leanring-buddy/PrivacyCaptureGuard.swift
   ```
   (`mkdir -p build/harness` first. It builds with the Command Line Tools; the embedded plist supplies the mic/speech usage strings.)
2. Run `build/harness/wake-word-harness` from Terminal. Grant Microphone and Speech Recognition to Terminal when prompted (System Settings, Privacy & Security, if it silently does nothing).
3. Detection rate: say "Hey Clicky" 20 times at normal volume ~1 m from the Mac, varying tone, with some room noise. Count printed `trigger:` lines. Note misses.
4. Latency: screen-record or watch the clock; the printed text is the partial result that matched. For an exact number, run the app later and read the `summon_trigger` signpost (category `latency`) in Instruments or `log stream --predicate 'category == "latency"'`.
5. Idle CPU: in another terminal run `top -pid $(pgrep wake-word-harness) -stats pid,cpu,mem` for a minute of silence, then with talk/music in the background.
6. False accepts: leave it running 1 h while you work normally (music, a call, YouTube, talking). Every `trigger:` line you did not cause is a false accept. Test speaker leak too: say "hey clicky" in a video and see if it triggers.
7. Paste the numbers into the table above (or send them to the lead).

## Behaviour notes

- `pauseListeningWhileSpeaking(true)` ignores detections while TTS plays, unless the default output device is Bluetooth (treated as headphones, so a spoken "Hey Clicky" barge-in works). Wired headphones report as built-in and are treated as speakers.
- Restarting the session after each trigger prevents the same utterance from firing twice.
