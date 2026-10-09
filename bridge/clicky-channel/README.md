# clicky-channel

Claude Code channel server for Clicky. Claude Code spawns it over stdio (via `~/ClickyWorkspace/.mcp.json`); it also listens on `127.0.0.1:8977` (`CLICKY_BRIDGE_PORT`) for the Swift app. API: `docs/fork/CONTRACTS.md` sections 2-5.

```
npm install && npm run build   # dist/index.js
npm test                       # node:test: HTTP, SSE, tools, and a stdio MCP round-trip
```

- Pinned `@modelcontextprotocol/sdk@1.32.1` (negotiates protocol 2025-11-25, not the 2026-07-28 revision Claude Code's v2 client refuses for channels). Verify with the startup notice after launch.
- Runtime files: `~/.clicky/bridge-token` (0600), `bridge.json`, `logs/bridge.log` (stderr is swallowed by Claude Code, so read the log). `CLICKY_HOME` overrides `~/.clicky` (tests).
- `channel_registered` in `/v1/health` flips true when Claude Code completes MCP initialization (channel notifications are never acknowledged, so this is the best signal).
- Only one instance owns the HTTP port; a second instance logs the error and stays MCP-only.
