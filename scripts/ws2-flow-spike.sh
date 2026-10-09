#!/bin/zsh
# Builds and runs the WS2 Wispr Flow spike harness (see docs/fork/research/05-wispr-flow-spike.md).
# Usage: scripts/ws2-flow-spike.sh [--activating] [--seconds=6] [-clicky.flow.<key> <value> ...]
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/ws2-flow-spike"
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.2 -o "$OUT" \
  scripts/ws2-flow-spike/main.swift leanring-buddy/WisprFlowDriver.swift leanring-buddy/VoiceInputPanel.swift
exec "$OUT" "$@"
