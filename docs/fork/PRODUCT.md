# What we're building

## The ask (Ayaan, Oct 8 2026, lightly cleaned up)

> The main functionality: I want to use **Wispr Flow** and have it input into this thing.
> When I want to summon it, I want to be **completely hands-off the keyboard**.
> It makes my screen go **semi-gray**, meaning *this* is the screen being captured.
> It then routes through a **Claude Code session** — headless/resumed or an open Claude Code session; the mechanism is up to us.
> In the future it should be able to **make its own folders** and use **Claude computer use**.
> The other big one: **summon computer use**. If I'm looking at a web page I can say
> *"Hey Clicky, come and do this and fill this page with my information."*

Other context:
- Start from the open-source Clicky (`farzaa/clicky`, MIT). Maintain a **public fork** on Ayaan's GitHub.
- Use the **Team plan** for the Claude Code session (Ayaan also has a personal plan).
- Build with Claude Code, using **subagents per functionality**.

## Interpretation and decisions

| Topic | Decision | Why |
|---|---|---|
| Summon | Wake phrase **"Hey Clicky"** (fully hands-free) + a single-tap hotkey as backup | "Completely hands-off" and "say Hey Clicky" both point at a wake word |
| Capture cue | Capture first, then dim the captured screen to ~30% gray with a "Clicky is looking" pill; dim lifts when the answer is drawn | Capture must not include the dim; upstream already excludes its own windows from capture |
| Which screen | The screen under the cursor by default; setting for all screens | Cheaper, fewer coordinate mistakes; matches "this is the screen" |
| Voice input | **Wispr Flow** transcribes into a Clicky input panel; Clicky starts/stops Flow itself and auto-submits. Built-in STT (Apple Speech on-device) is the fallback | Flow is the requirement; fallback keeps it working when Flow misbehaves |
| Voice output | macOS on-device speech by default; ElevenLabs optional | No keys needed to run |
| Brain | A **persistent interactive Claude Code session** (tmux `clicky`, working dir `~/ClickyWorkspace`) fed through a **Claude Code channel** (`bridge/clicky-channel`) | Keeps context warm, no per-turn startup, runs on the subscription |
| Fallback brain | `claude -p --resume <session>` per turn; upstream direct-API path kept as a third option | Works if channels are blocked |
| Point/teach | Claude replies with speech + shapes (circle, box, arrow, label, path, highlight) in screenshot pixels; Swift maps and draws; optional accessibility snapping | Same proven approach as upstream, more shapes |
| Do on web pages | **Claude in Chrome** from the same session (`--chrome`); works on the Team plan | Covers "fill this page with my information" |
| Do in native apps | Later: a second "doer" session on the **personal** plan with computer use (`CLAUDE_CONFIG_DIR`) | Claude Code computer use is Pro/Max only, not Team |
| Personal info | `~/.clicky/profile.md`, outside the repo, read only in do mode | Repo is public |
| Safety | Never type passwords, card numbers, government IDs; never submit/send/buy/delete without a spoken "yes" | Upstream's paid app does the same for deletes, emails, payments |
| Own folders | Claude may create folders only under `~/ClickyWorkspace/` | Future research/build tasks |

## Scenarios (acceptance stories)

1. **Point.** In Notes, Ayaan says "Hey Clicky, where do I change the font size?" without touching anything. The screen dims, Flow transcribes, Clicky speaks one or two sentences and circles the right control.
2. **Teach (steps).** "Hey Clicky, walk me through exporting this as PDF." Clicky draws step 1, waits until Ayaan clicks inside the target, then shows step 2.
3. **Do (web).** On a sign-up page in Chrome: "Hey Clicky, fill this page with my information." Clicky shows status bubbles, fills fields from the profile in that tab, reads back a summary, and asks "Submit?" before pressing anything final.
4. **Follow-up.** "Hey Clicky, and how do I make that the default?" uses the same conversation.
5. **Cancel.** "Hey Clicky, stop" or Esc cancels whatever is running and clears the screen.
6. **Later: research into a folder.** "Hey Clicky, research X and put notes in a folder." Claude creates `~/ClickyWorkspace/<slug>/`.

## Non-goals for now

Windows; notarized distribution; multiple users; selling it; always-on screen watching (we only capture on summon).

## Open questions / decisions (lead asks Ayaan in Phase 0)

1. **Decided:** Ayaan's main Claude Code login is a **Team plan** and he is **not an Owner**, so channels are blocked there, and no Clicky traffic may go to the Team org. Every `claude` process Clicky starts (session script and headless transport) runs on his **personal Pro** login via a separate config dir, `CLAUDE_CONFIG_DIR` (default `$HOME/.claude-personal`; override with env `CLICKY_CLAUDE_CONFIG_DIR` for scripts or the `clickyClaudeConfigDirectory` UserDefaults key for the app). If that dir is missing or logged out, Clicky reports the brain unavailable instead of using the default login. One-time: `scripts/clicky-session.sh login`.
   (Original question: is Ayaan an **Owner** of the Team org? Channels are blocked on Team plans until an Owner enables them (Organization settings → Claude Code → Channels). If not, use the personal plan for the session or the headless fallback.)
2. Apple Developer **Team ID** for signing (stable signing keeps macOS permissions from resetting).
3. Which **Wispr Flow shortcut** to dedicate to Clicky (the spike in WS2 decides what's synthesizable).
4. OK to keep the **microphone open** for the wake word? (macOS shows the orange mic dot.)
5. **Decided:** bundle ID is `com.rockyshaikh.clicky`.
6. **Decided:** the fork lives at github.com/RockyShaikh/clicky.
