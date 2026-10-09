# Clicky fork — project docs

This folder holds everything we learned before writing code, plus the plan for the fork.
The kickoff prompt for Claude Code lives at the repo root: [`kickoff.md`](../../kickoff.md).

## Reading order

1. [`PRODUCT.md`](PRODUCT.md) — what we're building, in Ayaan's words, plus decisions and open questions.
2. [`ARCHITECTURE.md`](ARCHITECTURE.md) — components, data flow, plans/auth, latency budget.
3. [`CONTRACTS.md`](CONTRACTS.md) — the interfaces every workstream codes against. Change these only on `main`, deliberately.
4. [`workstreams/`](workstreams/) — one brief per subagent (WS1–WS6).
5. [`research/`](research/) — background:
   - [`01-clicky-teardown.md`](research/01-clicky-teardown.md) — company, how upstream Clicky works, how it knows where to draw
   - [`02-claude-code-integration.md`](research/02-claude-code-integration.md) — channels, headless, MCP, Chrome, computer use, plan rules (verified Oct 8 2026)
   - [`03-voice-and-wispr-flow.md`](research/03-voice-and-wispr-flow.md) — Wispr Flow, wake word, hands-free input
   - [`04-grounding-and-drawing.md`](research/04-grounding-and-drawing.md) — coordinate accuracy, snapping, click detection
   - [`clicky-taken-apart.html`](research/clicky-taken-apart.html) — the original teardown page (open in a browser)
6. [`sketches/`](sketches/) — throwaway prototypes from the research (Hammerspoon pen, MCP screen pen). Reference only; not part of the app.

## Evidence labels used in research docs

- **[code]** read in `farzaa/clicky` at commit `a80fa80` (Apr 27 2026, the last public commit)
- **[company]** stated on heyclicky.com or its changelog
- **[docs]** Anthropic / Wispr documentation, fetched Oct 8 2026
- **[inference]** our reasoning, not confirmed

## Repo layout after the fork work lands (target)

```
leanring-buddy/            Swift app (upstream name kept on purpose; see AGENTS.md)
bridge/clicky-channel/     Node/TypeScript MCP channel server that Claude Code spawns
session-template/          CLAUDE.md + .mcp.json + settings for the ~/ClickyWorkspace session
scripts/clicky-session.sh  starts/attaches the persistent Claude Code session (tmux)
test-fixtures/             screenshots + expected targets, local test web forms
docs/fork/                 this folder
worker/                    upstream Cloudflare Worker (kept for the optional direct-API path)
```
