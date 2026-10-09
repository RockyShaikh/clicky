#!/usr/bin/env bash
# Create ~/.clicky/profile.md (mode 0600) from session-template/profile.template.md.
# Never overwrites an existing profile. The profile holds personal info and must stay outside the repo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLICKY_HOME="${CLICKY_HOME:-$HOME/.clicky}"
PROFILE_PATH="$CLICKY_HOME/profile.md"
TEMPLATE_PATH="$REPO_DIR/session-template/profile.template.md"

if [ -e "$PROFILE_PATH" ]; then
  echo "profile already exists, leaving it alone: $PROFILE_PATH"
  exit 0
fi

mkdir -p "$CLICKY_HOME"
umask 077
cp "$TEMPLATE_PATH" "$PROFILE_PATH"
chmod 600 "$PROFILE_PATH"
echo "created $PROFILE_PATH (0600). Edit it and fill in your details; it is never committed."
