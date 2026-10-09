#!/usr/bin/env bash
# Manage the persistent Claude Code session that backs Clicky.
# Usage: clicky-session.sh start | attach | stop | status
set -euo pipefail

# Billing/auth rule: an API key would bill the API instead of the subscription login.
unset ANTHROPIC_API_KEY

SESSION_NAME="clicky"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$REPO_DIR/bridge/clicky-channel"
TEMPLATE_DIR="$REPO_DIR/session-template"
WORKSPACE_DIR="$HOME/ClickyWorkspace"
CLICKY_HOME="${CLICKY_HOME:-$HOME/.clicky}"
PORT="${CLICKY_BRIDGE_PORT:-8977}"

require_command() {
  local command_name="$1" hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: '$command_name' not found. $hint" >&2
    exit 1
  fi
}

build_bridge_if_stale() {
  local needs_build=0
  if [ ! -d "$BRIDGE_DIR/node_modules" ]; then
    (cd "$BRIDGE_DIR" && npm install --no-audit --no-fund)
    needs_build=1
  fi
  [ -f "$BRIDGE_DIR/dist/index.js" ] || needs_build=1
  if [ "$needs_build" = 0 ] && [ -n "$(find "$BRIDGE_DIR/src" "$BRIDGE_DIR/package.json" -newer "$BRIDGE_DIR/dist/index.js" 2>/dev/null | head -1)" ]; then
    needs_build=1
  fi
  if [ "$needs_build" = 1 ]; then
    echo "building bridge..."
    (cd "$BRIDGE_DIR" && npm run build)
  fi
}

# Copies new template files into the workspace; never overwrites user edits (reports differences instead).
sync_template() {
  mkdir -p "$WORKSPACE_DIR"
  local relative_path source_file target_file rendered_source
  while read -r relative_path; do
    source_file="$TEMPLATE_DIR/$relative_path"
    target_file="$WORKSPACE_DIR/$relative_path"
    mkdir -p "$(dirname "$target_file")"
    rendered_source="$(mktemp)"
    sed "s|__CLICKY_REPO__|$REPO_DIR|g" "$source_file" > "$rendered_source"
    if [ ! -e "$target_file" ]; then
      mv "$rendered_source" "$target_file"
      echo "created $target_file"
    elif ! diff -q "$rendered_source" "$target_file" >/dev/null; then
      echo "kept your edited $target_file (template differs: diff $rendered_source $target_file)"
    else
      rm -f "$rendered_source"
    fi
  done < <(cd "$TEMPLATE_DIR" && find . -type f | sed 's|^\./||')
}

cmd_start() {
  require_command claude "Install Claude Code: https://code.claude.com"
  require_command node "Install Node 18+: brew install node"
  require_command tmux "Install tmux: brew install tmux"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "session '$SESSION_NAME' already running. Use: $0 attach"
    return 0
  fi
  build_bridge_if_stale
  sync_template
  tmux new-session -d -s "$SESSION_NAME" -c "$WORKSPACE_DIR" \
    "claude --dangerously-load-development-channels server:clicky --chrome --model sonnet"
  cat <<EOF
started tmux session '$SESSION_NAME'.
Run '$0 attach' once to:
  1. accept the development-channels warning dialog,
  2. approve the 'clicky' server from .mcp.json (first run only),
  3. /login if prompted (use /login, not an API key, so Chrome works).
Detach with ctrl-b d. Then check: $0 status
EOF
}

cmd_attach() {
  require_command tmux "Install tmux: brew install tmux"
  exec tmux attach -t "$SESSION_NAME"
}

cmd_stop() {
  require_command tmux "Install tmux: brew install tmux"
  if tmux kill-session -t "$SESSION_NAME" 2>/dev/null; then echo "stopped"; else echo "not running"; fi
}

cmd_status() {
  require_command tmux "Install tmux: brew install tmux"
  local pane=""
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "tmux: session '$SESSION_NAME' alive"
    pane="$(tmux capture-pane -p -t "$SESSION_NAME" 2>/dev/null || true)"
  else
    echo "tmux: not running (run: $0 start)"
  fi
  if printf '%s' "$pane" | grep -qi "blocked by org"; then
    echo "channels: BLOCKED BY ORG POLICY. A Team Owner must enable Organization settings > Claude Code > Channels, or run this session on a personal Pro/Max login."
  fi
  if printf '%s' "$pane" | grep -qi "development channels\|Enter to confirm\|trust"; then
    echo "pane: a dialog may be waiting for a keypress; run: $0 attach"
  fi
  if [ -f "$CLICKY_HOME/bridge-token" ]; then
    local token health
    token="$(tr -d '[:space:]' < "$CLICKY_HOME/bridge-token")"
    if health="$(curl -sf -m 3 -H "Authorization: Bearer $token" "http://127.0.0.1:$PORT/v1/health")"; then
      echo "bridge: $health"
      case "$health" in
        *'"channel_registered":true'*) echo "channel: registered" ;;
        *) echo "channel: NOT registered yet (check the startup notice in the pane; tail $CLICKY_HOME/logs/bridge.log)" ;;
      esac
    else
      echo "bridge: not reachable on 127.0.0.1:$PORT (Claude Code spawns it; is the session up?)"
    fi
  else
    echo "bridge: no token yet ($CLICKY_HOME/bridge-token); the bridge creates it on first start"
  fi
}

case "${1:-}" in
  start) cmd_start ;;
  attach) cmd_attach ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  *) echo "usage: $0 start|attach|stop|status" >&2; exit 2 ;;
esac
