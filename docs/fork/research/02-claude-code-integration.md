# Claude Code integration notes (verified against code.claude.com docs, Oct 8 2026)

Re-check anything marked *preview* — flags and contracts can change.

## Plan / auth matrix

| Capability | Team | Personal Pro/Max | Source |
|---|---|---|---|
| Channels | Blocked until an **Owner** enables *Organization settings → Claude Code → Channels* (`channelsEnabled`) | "Pro and Max users without an organization skip these checks entirely" | /docs/en/channels |
| Custom (non-allowlisted) channel | `--dangerously-load-development-channels server:<name>`; still subject to `channelsEnabled` | same flag | /docs/en/channels-reference |
| Claude in Chrome (`--chrome`) | ✅ "A direct Anthropic plan (Pro, Max, Team, or Enterprise)" | ✅ | /docs/en/chrome |
| Computer use (CLI/Desktop) | ❌ "not available on Team or Enterprise plans" | ✅ research preview, macOS (CLI), interactive only | /docs/en/computer-use |
| `claude -p` headless | ✅ | ✅ | /docs/en/headless |

Chrome integration "requires signing in with `/login`" — it stays off with an API key or a `claude setup-token` token.

## Policy text (legal-and-compliance)

- "OAuth authentication is intended exclusively for purchasers of Claude Free, Pro, Max, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications."
- "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users."
- It does not "prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription."
- "Advertised usage limits for Pro and Max plans assume ordinary, individual usage of Claude Code and the Agent SDK."

→ Our design (our own login, unmodified `claude` binary, personal use) fits. Don't distribute a build that uses anyone's login.

## Channels (primary transport)

- A channel is a local **stdio MCP server spawned by Claude Code** that declares `capabilities.experimental['claude/channel'] = {}` and emits `notifications/claude/channel` with `{content: string, meta: Record<string,string>}`.
- Claude sees `<channel source="<server name>" key="value">content</channel>`. **Meta keys: letters, digits, underscores only** — others silently dropped.
- Two-way: add `capabilities.tools = {}` and normal MCP tools (our `look`, `respond`, `status`, `confirm`); give `instructions` telling Claude how to handle events.
- Requirements: `@modelcontextprotocol/sdk` + Node/Bun/Deno. Bun not required.
- Register in `.mcp.json` (project) or `~/.claude.json` (user); start with `claude --dangerously-load-development-channels server:clicky`. A **full-screen warning dialog** appears at launch (one keypress in the tmux pane). First run in a project also asks to approve the new `.mcp.json` server.
- Startup notice confirms registration: "Channels (experimental) messages from server:… inject directly in this session". If you see "blocked by org policy", the Team Owner hasn't enabled channels.
- **No acknowledgements**: `mcp.notification()` resolves when written; events are dropped silently if the session didn't load the channel. Expose status via our own `/v1/health`.
- Events arriving while Claude is busy are **batched** into its next turn.
- If Claude hits a **permission prompt**, the session pauses until answered in the terminal. Pre-allow our tools; optionally declare `claude/channel/permission` to relay prompts (only with a gated sender).
- Docs note: on the v2 MCP client runtime, Claude Code **doesn't register a channel server that negotiates protocol revision 2026-07-28** → pin an SDK/protocol version that registers, and verify via the startup notice.
- `--channels` / dev flag don't appear in `claude --help` during the preview.

## Headless fallback (`claude -p`)

- `--output-format json` → `{result, session_id, …}`; with `--json-schema '<schema>'` the data is in `.structured_output`.
- `--continue` / `--resume <session_id>` keep one conversation across calls.
- `--input-format stream-json` exists (text | stream-json); an image-block-over-stdin example for the CLI was **not verified** — use a file path + Read tool, or our MCP `look` tool.
- `--allowedTools "Read,mcp__clicky__*"`, `--permission-mode dontAsk`, `--max-turns`, `--model sonnet`, `--append-system-prompt`.
- **Don't** use `--bare` (it never reads OAuth/keychain → needs an API key). **Unset `ANTHROPIC_API_KEY`** ("In non-interactive mode (-p), the key is always used when present").
- `claude setup-token` makes a 1-year subscription token for scripts (`CLAUDE_CODE_OAUTH_TOKEN`) — but Chrome integration won't work with it.
- `--mcp-config` with `-p` waits up to `MCP_TIMEOUT` (30 s default) for servers.

## MCP image results

"When an MCP tool returns a PNG, JPEG, GIF, or WebP image, Claude sees the image inline in the conversation. The inline copy may be scaled down…" → our `look` tool returns the 1280-px JPEG as image content, so no Read permission on `~/.clicky/shots` is needed.

## Claude in Chrome (do mode on web pages)

- `claude --chrome` or `/chrome` → "Enabled by default". Needs the Claude in Chrome extension ≥ 1.0.36, signed in to the same account.
- "Claude opens new tabs for browser tasks and shares your browser's login state." Tabs go in a tab group tied to the session. **Spike (WS5):** acting on the user's *existing* current tab when they say "this page" (the extension's tab-context tool lists tabs; confirm Claude can select one).
- Pauses on login pages / CAPTCHAs and asks you to handle them. JS dialogs (alert/confirm) block the extension.
- Site permissions are managed in the extension; first action on a site prompts in the terminal.
- Service worker can go idle in long sessions → `/chrome` → Reconnect.

## Computer use (native apps — later, personal plan)

- CLI: enable the built-in `computer-use` MCP server via `/mcp`; macOS; grants Accessibility + Screen Recording; per-app approval per session; other apps hidden while Claude works; Esc aborts; one session holds the lock.
- Screenshots auto-downscaled (e.g. 3456×2234 → ~1372×887).
- **Interactive only** (not `-p`). **Pro/Max only.**
- Plan for a second session: `CLAUDE_CONFIG_DIR=$HOME/.claude-personal claude` then `/login` with the personal account (docs show `CLAUDE_CONFIG_DIR` as an absolute path setting; verify login isolation on first use).

## API computer-use tool (only if we ever add an API-key path)
Current `computer_toolset_20260801` (no beta header, includes `zoom`); earlier `computer_20251124` + `anthropic-beta: computer-use-2025-11-24`. Recommended sizes: 1024×768 / 1280×720 general; 1280×800 / 1366×768 web; avoid > 1920×1080. Coordinates in screenshot pixels, top-left.

## Building with subagents (for the lead)

- Project agents: `.claude/agents/*.md` with frontmatter `name`, `description`, `tools`, `model`, `isolation: worktree`. (Upstream `.gitignore` ignores `.claude/`.)
- `isolation: worktree` branches **from the default branch, not the parent's HEAD** → commit contracts/docs to `main` before spawning.
- Default concurrency limit 20 subagents; background subagents surface permission prompts in the main session.

## Gotchas checklist
- [ ] `unset ANTHROPIC_API_KEY` everywhere Claude Code is launched by our scripts.
- [ ] Session started with `/login` (not setup-token) so Chrome works.
- [ ] Team Owner enabled Channels, or use the personal plan for the session.
- [ ] `.mcp.json` server approved once; dev-channel warning acknowledged at each launch.
- [ ] `mcp__clicky__*` pre-allowed; Chrome site permissions granted for test sites.
- [ ] Bridge reports `channel_registered: true` before the app sends.
