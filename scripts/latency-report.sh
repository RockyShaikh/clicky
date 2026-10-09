#!/usr/bin/env bash
# Summarize Clicky latency logs. Usage: scripts/latency-report.sh [--dir DIR] [file ...]
# Defaults to ~/.clicky/logs/*.log. Parsing lives in latency-report.mjs (Node).
set -euo pipefail
exec node "$(cd "$(dirname "$0")" && pwd)/latency-report.mjs" "$@"
