# Kickoff — Clicky fork

**How to use:** in Terminal, `cd /Users/rocky/Projects/Clicky && claude`, then say: *"Read kickoff.md and run it."*
This file is the starting prompt for the **lead** Claude Code session. Everything below is addressed to you, the lead.

---

You are the **lead engineer** on a personal, public fork of [farzaa/clicky](https://github.com/farzaa/clicky) (MIT) for **Ayaan**. This repo is a fresh clone of upstream at `a80fa80` with the `upstream` remote set; we add our work on top. Your job is to set the fork up, then **build it with subagents — one per functionality** — and integrate their work.

## 0. Read first (in this order, before any edits)

1. `AGENTS.md` (CLAUDE.md is a symlink to it) — upstream conventions + the **Fork context** section at the top
2. `docs/fork/README.md` → `PRODUCT.md` → `ARCHITECTURE.md` → `CONTRACTS.md`
3. `docs/fork/workstreams/WS1…WS6` (skim; your subagents read them in full)
4. `docs/fork/research/01…04` (background; skim 02 carefully — plan rules and channel gotchas)

## 1. Mission (one paragraph)

Ayaan says **"Hey Clicky"** with his hands off the keyboard. Clicky captures the screen under his cursor, then dims that screen to semi-gray so he knows what's being looked at. **Wispr Flow** transcribes what he says into Clicky. Clicky routes it into a **persistent Claude Code session** through a **Claude Code channel**, and Claude answers by speaking and drawing on the screen (point/teach), or by **acting in Chrome** ("fill this page with my information") with spoken confirmation before anything final. Later: native-app computer use on his personal plan, and Claude creating its own folders under `~/ClickyWorkspace`.

## 2. Ground rules for you and every subagent

- Follow AGENTS.md style (long, explicit names; clarity over cleverness; comments explain *why*).
- **Public repo.** Never commit API keys, tokens, `~/.clicky/*`, screenshots of Ayaan's screen, or personal info. Keep `LICENSE` and upstream attribution.
- **Workstreams add new files; only you edit shared files**: `CompanionManager.swift`, `OverlayWindow.swift`, `CompanionPanelView.swift`, `leanring_buddyApp.swift`, `Info.plist`, `project.pbxproj`. The app target uses a file-system-synchronized group, so new Swift files in `leanring-buddy/` need no pbxproj edits.
- **Compile-only check** (allowed): `xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug -derivedDataPath build/agent-check CODE_SIGNING_ALLOWED=NO build`. Never launch that build and never run the signed app from the terminal (macOS permission resets). **Ayaan runs and permission-tests from Xcode.**
- Anything that launches `claude` from our scripts must `unset ANTHROPIC_API_KEY` and must not use `--bare` (both would bypass the subscription).
- `CONTRACTS.md` is the source of truth between workstreams. Change it only on `main`, bump its version line, and tell affected agents.
- Ask Ayaan only when blocked, and batch questions into one numbered message.

## 3. Phase 0 — preflight and fork setup (you, no subagents)

1. **Preflight.** Run and report a table: `git remote -v` (expect `upstream`), `claude --version`, `gh auth status`, `node -v` (≥ 18), `tmux -V`, `xcodebuild -version`, `sw_vers`, `test -z "$ANTHROPIC_API_KEY" && echo unset`, Wispr Flow installed (`ls /Applications | grep -i wispr`), Google Chrome installed. Ask before installing anything (e.g. `brew install tmux`).
2. **Ask Ayaan (one message):**
   a. Which account is this Claude Code session logged into (`/status`)? He wants the **Team** plan. Is he an **Owner** of that org? Channels are blocked on Team until an Owner turns on *Organization settings → Claude Code → Channels*. If not, choose: personal plan for the `clicky` session, or the headless fallback.
   b. Apple Developer **Team ID** for signing (stable signing keeps macOS permissions from resetting every build).
   c. Is the **Claude in Chrome** extension installed and signed in to the same account?
   d. OK to keep the mic open for the "Hey Clicky" wake word (orange mic dot)?
3. **Fork on GitHub (public):** `gh repo fork --remote --remote-name origin` (forks `farzaa/clicky` to Ayaan's account and adds it as `origin`; `upstream` stays). Then `git push -u origin main`. Confirm the fork URL.
4. **Make the fork ours (one commit each):**
   - Commit the docs as they are: `git add kickoff.md AGENTS.md .gitignore docs/fork && git commit -m "Add fork research, architecture, contracts and kickoff plan"`.
   - **Disable upstream analytics:** `ClickyAnalytics.swift` hardcodes upstream's PostHog key, so our builds would report to upstream's project. Gate every call behind `isAnalyticsEnabled` (default `false`) and remove the key from the source.
   - Keep the Sparkle updater disabled (`startSparkleUpdater()` is already commented out; `SUFeedURL` points to someone else's appcast). Leave a comment why.
   - Signing: set `DEVELOPMENT_TEAM` to Ayaan's Team ID and `PRODUCT_BUNDLE_IDENTIFIER` to `com.<ayaan-github-handle>.clicky` (+ `.clicky-tests` etc. for test targets) across configs. Keep the scheme name.
   - Point `workerBaseURL` usage behind the transport selector later; for now leave it.
5. Baseline **compile check**. Fix only what blocks compiling.
6. **Review `CONTRACTS.md`** against the code you've now read. Fix anything wrong and commit to `main`. Subagent worktrees branch **from the default branch**, so contracts must be on `main` before Phase 1.
7. Push `main`. Post a short Phase 0 report to Ayaan.

## 4. Phase 1 — build in parallel with subagents

Spawn these **at the same time**, each as a background subagent with `isolation: "worktree"` (one git worktree per agent):

| Agent | Brief | Branch | Notes |
|---|---|---|---|
| `ws1-summon-capture` | `docs/fork/workstreams/WS1-summon-and-capture.md` | `ws/summon-capture` | Wake-word spike needs Ayaan's voice; agent prepares a test harness + steps |
| `ws2-voice-io` | `docs/fork/workstreams/WS2-voice-input-wispr-flow.md` | `ws/voice-io` | Wispr Flow spike needs Ayaan's Mac; same pattern |
| `ws3-bridge` | `docs/fork/workstreams/WS3-claude-code-bridge.md` | `ws/bridge` | Critical path; start its E2E as soon as possible |
| `ws4-annotations` | `docs/fork/workstreams/WS4-annotation-renderer.md` | `ws/annotations` | Pure Swift + tests; no hardware dependency |
| `ws6-qa` | `docs/fork/workstreams/WS6-qa-evals-latency.md` | `ws/qa` | Fixtures first; WS3 needs them |

Prompt template for each (fill in the brackets):

> You are the **[agent]** engineer on the Clicky fork. Read `AGENTS.md`, then `[brief]` and everything it lists under "Read first". Create and work on branch `[branch]` in your worktree. Stay inside the files your brief says you own; if you need a shared-file change, describe it instead of making it. Commit in small, clearly described steps. Run the compile-only check (and your tests) before you finish. Don't push. Finish with: summary, files added/changed, test results, manual test steps for Ayaan, open issues, and anything you need from the lead or Ayaan.

While they run:
- Answer their questions and relay hardware/voice steps to Ayaan in batched messages (subagents can't talk to him directly).
- When an agent finishes: review the diff, run the compile check on its branch, then `git merge --no-ff [branch]` into `main`. Resolve conflicts yourself. Push.
- If two agents need the same contract change, make it once on `main` and tell both.

## 5. Phase 2 — integrate, then do mode

1. **You:** add `leanring-buddy/HandsFreeSessionCoordinator.swift` implementing the state machine in ARCHITECTURE.md, composing `SummonTriggerProvider` → `ScreenCaptureForRequestProvider` → `VoiceUtteranceProvider` → `BrainTransport` → `AnnotationLayerState` + `SpokenResponseOutput`. Start it from `CompanionManager` without breaking upstream's hold-to-talk path. Mount `CaptureDimLayerView`, `AnnotationLayerView` (and later `DoModeStatusBubbleView`) in `OverlayWindow` per CONTRACTS §7. Point the blue-cursor flight at the `primary` shape. Add settings in `CompanionPanelView`: brain transport (channel/headless/direct), voice input (Wispr Flow/Apple Speech), wake word on/off + sensitivity, dim strength, capture all screens.
2. Ayaan runs from Xcode, grants Mic / Accessibility / Screen Recording / Speech Recognition, starts the session with `scripts/clicky-session.sh start` (+ `attach` once to accept the dev-channel warning), and tries **Scenario 1** (PRODUCT.md).
3. Once Scenario 1 works through the channel, spawn **`ws5-do-mode`** (brief `WS5-do-mode.md`, branch `ws/do-mode`, worktree) and have **`ws6-qa`** run the E2E checklist with Ayaan; log results and latency in `docs/fork/QA-LOG.md`.

## 6. Phase 3 — later (only after Ayaan says go)

Native-app computer use via a second session on the **personal** plan (`CLAUDE_CONFIG_DIR`, design from WS5); spoken approval of Claude Code permission prompts via channel permission relay; research tasks that create folders in `~/ClickyWorkspace`; per-app notes library; zoom-refine and Set-of-Mark grounding; occasional `git fetch upstream && git merge upstream/main`.

## 7. Done for this kickoff when

- [ ] Public fork exists on Ayaan's GitHub with these docs committed; analytics disabled; signing set.
- [ ] WS1, WS2, WS3, WS4, WS6 merged to `main`; compile check green; tests pass.
- [ ] Scenario 1 (hands-free point) works end to end on Ayaan's Mac via the channel (or headless, if channels are blocked), with latency numbers in `docs/fork/QA-LOG.md`.
- [ ] WS5 started or scheduled, with Ayaan's answers to the open questions recorded in `docs/fork/PRODUCT.md`.

## 8. Reporting to Ayaan

At each phase boundary send a short update: what's done, what's blocked, what you need from him (numbered), what's next. Keep it skimmable.
