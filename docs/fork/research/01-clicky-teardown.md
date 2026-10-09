# Clicky teardown (researched Oct 8 2026)

Labels: **[code]** farzaa/clicky @ a80fa80 · **[company]** heyclicky.com + changelog · **[inference]** ours.

## 1. The company

| | |
|---|---|
| Entity | Humansongs, Inc. (San Francisco). Renamed "Clicky" → "HeyClicky" on May 30 2026 (v1.0.21). |
| Founder | Farza Majeed (previously buildspace, wound down 2024). |
| Backing | Y Combinator Spring 2026; no other round disclosed as of June 2026. |
| Launch | v1.0 on Apr 6 2026. Weekend project → open-sourced v1 under MIT. Launch video ~3M views; repo ~6.3k stars by June (DailyDropout). |
| Platform | macOS 14.2+; Windows waitlist. |
| Pricing | Free (25 talk + 25 agent msgs/mo) · Pro $20/mo (unlimited talk/dictation, 150 agent msgs) · Max $100/mo (1,000 agent msgs). Yearly −20%. Students −50% first Pro month. |
| Claimed users | "25,000+" (self-reported). |
| Vendors named | Privacy policy: Anthropic, OpenAI, Deepgram, Cerebras; PostHog. Trust page: requests go to "either anthropic or openai"; Sentry. |
| Privacy | Screen captured only on hotkey; screenshots "never stored"; text summaries kept; no SOC 2 yet. |

## 2. Product evolution [company]

| Date (2026) | Ver | Change |
|---|---|---|
| Apr 6 | 1.0 | Sees screen, answers aloud, points with blue cursor |
| Apr 30 | 1.0.11 | "A fast intent classifier" routes to agents |
| May 4 | 1.0.12 | Computer control "thanks to our friends at Cua" |
| May 30 | 1.0.21 | Draw-on-screen guidance: "target rings, annotations, and narration"; realtime voice default |
| Jun 18 | 1.0.25 | User can draw on screen (Ctrl+Option) to show what they mean |
| Jun 19 | 1.0.26 | Step-by-step walkthroughs "made much smarter by skill files"; "detects when you click where it told you to" |
| Jun 23 | 1.0.28 | Teaching skills for 89 apps |
| Jul 1 | 1.0.31 | "Claude Fable 5 is now the default"; Always On limited to headphones |
| Jul 6 | 1.0.33 | Realtime voice → gpt-realtime-2.1 |
| Jul 17 | 1.0.40 | Hand-drawn, Excalidraw-style shapes |
| Jul 31 | 1.0.45 | "A little router decides on every question" (fast vs frontier) |
| Aug 25 | 1.0.48 | Native computer-use driver; walkthroughs up to 15 steps |
| Sep 12 | 1.0.49 | "Clickys": named assistants with memory, routines, custom MCP connectors |
| Sep 24 | 1.0.52 | "Your Clickys now run on GPT-6 Luna, and deep answers use GPT-6 Sol." |

The public repo stops at Apr 27 2026; README says new work is private.

## 3. How v1 works [code]

1. Hold **Ctrl+Option** — listen-only `CGEvent` tap (`GlobalPushToTalkShortcutMonitor.swift`).
2. Mic via `AVAudioEngine` → **AssemblyAI** realtime (`u3-rt-pro`); fallbacks OpenAI upload and Apple Speech (`BuddyTranscriptionProvider.swift`, Info.plist `VoiceTranscriptionProvider`).
3. **ScreenCaptureKit** captures every display, long edge **1280 px**, JPEG q0.8, **own windows excluded** via `SCContentFilter(display:excludingWindows:)`; cursor screen sorted first (`CompanionScreenCaptureUtility.swift`).
4. Each image labeled `"screen N of M — cursor is on this screen (primary focus)"` + `"(image dimensions: WxH pixels)"`.
5. Claude **Sonnet 4.6** (Opus 4.6 optional) via a **Cloudflare Worker** that holds keys; SSE; last 10 exchanges (`ClaudeAPI.swift`, `worker/src/index.ts`).
6. Regex strips `[POINT:x,y:label:screenN]` from the end of the reply (`CompanionManager.parsePointingCoordinates`).
7. **ElevenLabs** `eleven_flash_v2_5` speaks the reply.
8. Full-screen, non-activating `NSPanel` overlay (joins all Spaces) — blue cursor flies a quadratic bezier to the target (`OverlayWindow.swift`).
9. PostHog analytics (`ClickyAnalytics.swift`) — **we should strip or disable this in the fork.**

## 4. How it knows where to draw

### 4.1 Prompt contract [code]
`CompanionManager.swift` (~L544–577) system prompt: coordinate space = screenshot pixels as labeled, origin top-left; append `[POINT:x,y:label]` (or `:screenN`) at the very end, or `[POINT:none]`; four few-shot examples (Final Cut color inspector `[POINT:1100,42:color inspector]`, Xcode source control `[POINT:285,11:source control]`, a second-monitor case, and a conceptual question with `[POINT:none]`). Tag stripped before TTS and history.

### 4.2 Mapping [code]
Clamp → scale image px to display points → flip Y for AppKit → add display origin.
Example: (1100, 42) in 1280×831 → display 1512×982 → x = 1100×1512/1280 = 1299.4; y = 42×982/831 = 49.6 → AppKit y = 982 − 49.6 = 932.4 (+ origin).

### 4.3 Unused second technique [code]
`ElementLocationDetector.swift` uses Claude's **computer-use tool as a pointing oracle**: declare `computer_20251124` sized to the screenshot (1024×768 / 1280×800 / 1366×768 by aspect ratio), ask Claude to "click on that element", read `coordinate` from the `tool_use` block, never click. Comment: the tool "activates Claude's specialized pixel-counting training, which is significantly more accurate than regular vision API coordinate extraction." **Nothing calls this class in the public repo.** It also documents a Retina bug: `NSImage.lockFocus()` renders at 2× so the sent image no longer matches the declared size → wrong-scale coordinates; fixed with `NSBitmapImageRep` at exact pixel size.

### 4.4 Where the skill comes from [docs]
Anthropic, *Developing a computer use model*: "Training Claude to count pixels accurately was critical." Claude vision docs: "Claude works best with absolute pixel coordinates"; it "does not work well when you ask for normalized coordinates" (0–1000 is Gemini's convention). Resize the image yourself so "the image you have is exactly the image Claude sees."

### 4.5 Verdict
**Prompting + deterministic code on top of lab-trained grounding.** No sign Clicky fine-tunes: v1 is prompt + regex + math; the default model moved Claude Sonnet 4.6 → Claude Fable 5 → GPT-6 Luna in six months (a fine-tune wouldn't carry across vendors); later gains are context and product engineering (skill files, router, walkthrough state, click detection). Fine-tuning exists upstream in open grounding models (UI-TARS, OmniParser, Holo, GTA1).

## 5. What the paid app added
- [company] Per-app **skill files** (89 apps). [inference] Markdown injected by frontmost app/site.
- [company] Walkthroughs that **notice your click**. [inference] global mouse-down hit-test vs target rect, then re-screenshot.
- [company] Hand-drawn shapes. [inference] renderer adds wobble; model emits primitives.
- [company] **Router** fast vs frontier. [inference] Cerebras likely serves a fast classifier.
- [company] **Computer use** via Cua, then a native driver — "do it" mode separate from "show me".

## 6. Why it can't run on a Claude subscription [docs]
Claude Code legal page: OAuth (Free/Pro/Max/Team/Enterprise) "is designed to support ordinary use of Claude Code and other native Anthropic applications"; "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users." Blocking began Jan 9 2026; docs clarified Feb 19 2026. Clicky also runs mostly on OpenAI now. Our fork is fine because **we run the unmodified Claude Code binary with our own login** for personal use.

## 7. Moat assessment
Not the core idea (prompt + regex + transparent window; given away under MIT; a Windows port followed). The moat is distribution (founder audience, YC, ~3M-view launch), packaging (no keys, no setup), accumulated tuning (skills for ~100 apps, walkthroughs, click detection, barge-in voice, router) and shipping speed (~50 releases in 6 months). Fragile: better model grounding helps every copycat; margins depend on vendor token prices; platforms (Claude/ChatGPT desktop computer use, Apple on-screen Siri) are moving in. The pivot to named assistants/connectors/routines suggests they know it.

## 8. Sources
- https://www.heyclicky.com/ · /changelog · /trust · /privacy-policy
- https://github.com/farzaa/clicky (README, AGENTS.md, CompanionManager.swift, ElementLocationDetector.swift, CompanionScreenCaptureUtility.swift)
- https://github.com/Bitshank-2338/clicky-windows (community Windows port: grid two-stage locator, privacy guard)
- https://dailydropout.substack.com/p/heyclicky-give-your-cursor-infinite (Jun 9 2026)
- https://www.anthropic.com/news/developing-computer-use
- https://platform.claude.com/docs/en/build-with-claude/vision-coordinates
- https://code.claude.com/docs/en/legal-and-compliance
- https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/
