# Sketches (reference only)

Prototypes from the research phase. They are **not** part of the app and were never run on a Mac; keep them as a fast way to test ideas.

- `hammerspoon/` — Path A from the teardown: a Hammerspoon "pen" (click-through overlay on `localhost:7777/draw`) + a hotkey that screenshots, asks for a question, and calls `claude -p` with a JSON schema.
  - `init.lua` → `~/.hammerspoon/init.lua`; `ask.sh` + `schema.json` → `~/.screenpen/`
- `mcp/screenpen_mcp.py` — Path B: an MCP server with `capture_screen` (image result) and `draw_on_screen` (posts to the Hammerspoon pen), usable from Claude Code or Claude Desktop.

Quick pen test once Hammerspoon is running:
`curl -d '{"imgW":1280,"imgH":800,"shapes":[{"kind":"circle","x":640,"y":400}]}' localhost:7777/draw`
