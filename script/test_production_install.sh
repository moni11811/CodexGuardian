#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/Codex Guardian.app"
HELPER="$APP/Contents/SharedSupport/codex-guardian-mcp"
DAEMON="$APP/Contents/SharedSupport/guardian-daemon"
CLI="$APP/Contents/SharedSupport/guardianctl"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.moni.codexguardian.plist"
DAEMON_LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.moni.codexguardian.daemon.plist"
STATE_DIR="$HOME/Library/Application Support/CodexGuardian"
CONFIG="$HOME/.codex/config.toml"

test -x "$APP/Contents/MacOS/CodexGuardian"
test -x "$HELPER"
test -x "$DAEMON"
test -x "$CLI"
test -f "$LAUNCH_AGENT"
test -f "$DAEMON_LAUNCH_AGENT"
test -f "$APP/Contents/Resources/CodexGuardian.icns"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" | /usr/bin/grep -Fxq 'CodexGuardian'
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/plutil -lint "$LAUNCH_AGENT" >/dev/null
/usr/bin/plutil -lint "$DAEMON_LAUNCH_AGENT" >/dev/null
/usr/bin/grep -Fq "command = \"$HELPER\"" "$CONFIG"
test "$(/usr/bin/stat -f '%Lp' "$STATE_DIR")" = "700"
for credential in mac-ui.token mcp.token cli.token; do
  test "$(/usr/bin/stat -f '%Lp' "$STATE_DIR/credentials/$credential")" = "600"
  test "$(/usr/bin/stat -f '%z' "$STATE_DIR/credentials/$credential")" = "32"
done
/bin/launchctl print "gui/$(id -u)/com.moni.codexguardian.daemon" >/dev/null
CLI_OUTPUT="$("$CLI")"
[[ "$CLI_OUTPUT" == *'"snapshot"'* ]]

printf '%s\n' "Production installation test passed"
