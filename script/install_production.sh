#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/CodexGuardian.app"
INSTALL_APP="/Applications/Codex Guardian.app"
LAUNCH_AGENT_SOURCE="$ROOT_DIR/support/com.moni.codexguardian.plist"
LAUNCH_AGENT_DEST="$HOME/Library/LaunchAgents/com.moni.codexguardian.plist"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/com.moni.codexguardian"

"$ROOT_DIR/script/build_and_run.sh" --build-only

mkdir -p "$HOME/Library/LaunchAgents"
/usr/bin/ditto "$SOURCE_APP" "$INSTALL_APP"
/bin/cp "$LAUNCH_AGENT_SOURCE" "$LAUNCH_AGENT_DEST"

/usr/bin/xattr -cr "$INSTALL_APP"
/usr/bin/codesign --force --sign - "$INSTALL_APP/Contents/SharedSupport/codex-guardian-mcp"
/usr/bin/codesign --force --deep --sign - "$INSTALL_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/plutil -lint "$LAUNCH_AGENT_DEST" >/dev/null

/bin/launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
/usr/bin/pkill -x CodexGuardian >/dev/null 2>&1 || true
/bin/launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT_DEST"
/bin/launchctl kickstart -k "$SERVICE"

printf '%s\n' "Installed $INSTALL_APP"
