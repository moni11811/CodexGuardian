#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/Codex Guardian.app"
HELPER="$APP/Contents/SharedSupport/codex-guardian-mcp"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.moni.codexguardian.plist"
CONFIG="$HOME/.codex/config.toml"

test -x "$APP/Contents/MacOS/CodexGuardian"
test -x "$HELPER"
test -f "$LAUNCH_AGENT"
test -f "$APP/Contents/Resources/CodexGuardian.icns"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" | /usr/bin/grep -Fxq 'CodexGuardian'
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/plutil -lint "$LAUNCH_AGENT" >/dev/null
/usr/bin/grep -Fq "command = \"$HELPER\"" "$CONFIG"

printf '%s\n' "Production installation test passed"
