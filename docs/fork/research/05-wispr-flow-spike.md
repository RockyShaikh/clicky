# Wispr Flow spike (WS2)

**Status: NOT YET RUN.** It needs Ayaan's Mac with Flow configured. This file holds what is known, the harness, the exact steps, and a results template. Fill in the results and the "Chosen" block, then WS2 defaults can be finalized.

## Known (read-only inspection)
- Wispr Flow 1.6.1102 at `/Applications/Wispr Flow.app`, bundle ID `com.electron.wispr-flow` (Electron). `WisprFlowDriver` uses this to detect whether Flow is running.
- Its preferences are not in `defaults` (only window metadata), so its hotkey config is in-app; it could not be read from here.

## Harness
`scripts/ws2-flow-spike.sh` builds `scripts/ws2-flow-spike/main.swift` with `WisprFlowDriver.swift` and `VoiceInputPanel.swift` (the real production classes) and runs a standalone tool: it shows the panel, sends Flow's trigger, waits `--seconds` (default 6), sends the trigger again, then prints a timestamped log of every text change in the panel plus the frontmost app before and after.
Terminal needs Accessibility permission (System Settings > Privacy & Security > Accessibility) to post events. This is a separate throwaway tool, not the Clicky app.

Flags: `--activating` (activate our app so paste lands; tests Q3 fallback), `--seconds=N`, and defaults overrides:
`-clicky.flow.triggerKind keyChord|mouseButton`, `-clicky.flow.triggerKeyCode <int>`, `-clicky.flow.triggerModifiers <CGEventFlags raw int>`, `-clicky.flow.triggerMouseButton <2|3|4>`, `-clicky.flow.startTapCount <n>`, `-clicky.flow.stopTapCount <n>`.
Default trigger: key code 105 (F13), no modifiers, 1 tap to start, 1 to stop.
Modifier raw values: shift 131072, control 262144, option 524288, command 1048576 (sum for chords).

## Manual steps (about 30 min)
1. In Wispr Flow settings, bind a dedicated shortcut: **F13** (or a chord such as ctrl+opt+cmd+F, or a spare mouse button 4/5). Avoid Fn/Globe: it cannot be synthesized reliably. Note which Flow mode it drives (push-to-talk vs toggle vs hands-free).
2. Grant Terminal Accessibility. Open TextEdit-like app so there is a "previous frontmost app" to watch.
3. **Q1 trigger**: `scripts/ws2-flow-spike.sh --seconds=5`, speak a sentence while it records. Did Flow start (its UI/sound) and insert text into the panel? Repeat with a chord (`-clicky.flow.triggerKeyCode 3 -clicky.flow.triggerModifiers 1835008` is ctrl+opt+cmd+F) and with a mouse button (`-clicky.flow.triggerKind mouseButton -clicky.flow.triggerMouseButton 3`); for the mouse case check the app under the cursor did not react.
4. **Q2 hands-free semantics**: if the trigger is push-to-talk (hold), a tap pair will not work; try `-clicky.flow.startTapCount 2` (double-tap = hands-free, stop = 1 tap). Also: say a sentence and stay silent; does Flow stop by itself, and after how long?
5. **Q3 insertion**: read the log. One big "text changed" = paste; many = keystrokes/streaming. Did text land in the non-activating panel? If not, rerun with `--activating` and check "frontmost now" returns to the original app (coordinator restores it; the harness does not).
6. **Q4 latency**: time between `STOP trigger sent` and the first/last text change line.
7. **Q5**: with screen recording of your own, check whether Flow's pill/overlay is visible in a Clicky screenshot (we capture before starting Flow, so expected harmless).
8. Test with Flow quit: harness should print `Flow running: false` (coordinator then uses Apple Speech).

## Results (to fill in)
| Q | Finding |
|---|---|
| 1 trigger | |
| 2 hands-free / auto-stop | |
| 3 insertion + non-activating panel | |
| 4 stop-to-text latency | |
| 5 Flow UI in screenshot | |

**Chosen:** trigger = ___ , start taps = ___ , stop taps = ___ , panel activation mode = nonactivating / activating.
**Flow settings Ayaan must set:** the shortcut above, hands-free enabled (if used), and the microphone set to the same input as the Mac default.

## Implementation notes
- Coordinator flow: panel shown, Flow started, our VAD (900 ms silence after 300 ms speech, 30 s cap, 8 s no-speech timeout) decides end, Flow stopped, field text must be non-empty and unchanged 500 ms, 2.5 s deadline then Apple Speech on the ring buffer.
- Settings keys: `clicky.voice.endOfSpeechSilenceSeconds`, `clicky.voice.minimumSpeechSeconds`, `clicky.voice.speechRMSThreshold`, `clicky.voice.panelActivationMode`, `clicky.voice.speechRate`, `clicky.voice.voiceIdentifier`, plus the `clicky.flow.*` keys above.
