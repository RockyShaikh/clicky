# Native computer use (Phase 3 design, not built)

Goal: act in native apps ("Hey Clicky, rename these files in Finder") through Claude Code computer use.

- Second tmux session `clicky-doer` on the personal plan: `CLAUDE_CONFIG_DIR=$HOME/.claude-personal`, `ANTHROPIC_API_KEY` unset, no `--bare`, cwd `~/ClickyWorkspace-doer`.
- Second bridge instance on port 8978 (`CLICKY_BRIDGE_PORT`), MCP server name `clicky_doer`, its own `.mcp.json` and token file; the app picks the target by request mode (`do` + non-browser frontmost app).
- Same `confirm` rule and profile rule as web do mode; the session CLAUDE.md reuses the WS5 section, with "Chrome" replaced by computer-use tools.
- Open questions: computer-use availability on the personal plan, Screen Recording and Accessibility grants for the tmux host terminal, and how the app dims or hides its overlay while the doer clicks.
