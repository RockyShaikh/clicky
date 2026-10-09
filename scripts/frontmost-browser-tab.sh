#!/usr/bin/env bash
# Prints the URL (line 1) and title (line 2) of Google Chrome's active tab, or nothing when Chrome
# has no window. The Swift app runs the same AppleScript (DoModeRequestClassifier.swift).
# First run asks for Automation permission for the calling app.
set -euo pipefail

osascript <<'APPLESCRIPT'
tell application "Google Chrome"
    if (count of windows) is 0 then return ""
    set activeTabURL to URL of active tab of front window
    set activeTabTitle to title of active tab of front window
    return activeTabURL & linefeed & activeTabTitle
end tell
APPLESCRIPT
