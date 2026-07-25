#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexGuardian"
BUNDLE_ID="com.moni.codexguardian"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_SHARED_SUPPORT="$APP_CONTENTS/SharedSupport"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
MCP_DIR="$DIST_DIR/bin"
ICON_SOURCE="$ROOT_DIR/Assets/CodexGuardian.svg"
ICONSET="$DIST_DIR/CodexGuardian.iconset"
ICON_FILE="$APP_RESOURCES/CodexGuardian.icns"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build
BUILD_DIR="$(swift build --show-bin-path)"

mkdir -p "$APP_MACOS" "$APP_SHARED_SUPPORT" "$APP_RESOURCES" "$MCP_DIR" "$ICONSET"
APP_BINARY_NEXT="$APP_BINARY.next"
MCP_BINARY="$MCP_DIR/codex-guardian-mcp"
MCP_BINARY_NEXT="$MCP_BINARY.next"
EMBEDDED_MCP_BINARY="$APP_SHARED_SUPPORT/codex-guardian-mcp"
EMBEDDED_MCP_BINARY_NEXT="$EMBEDDED_MCP_BINARY.next"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY_NEXT"
cp "$BUILD_DIR/codex-guardian-mcp" "$MCP_BINARY_NEXT"
cp "$BUILD_DIR/codex-guardian-mcp" "$EMBEDDED_MCP_BINARY_NEXT"
chmod +x "$APP_BINARY_NEXT" "$MCP_BINARY_NEXT" "$EMBEDDED_MCP_BINARY_NEXT"
mv -f "$APP_BINARY_NEXT" "$APP_BINARY"
mv -f "$MCP_BINARY_NEXT" "$MCP_BINARY"
mv -f "$EMBEDDED_MCP_BINARY_NEXT" "$EMBEDDED_MCP_BINARY"

for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  filename="${spec#* }"
  /usr/local/bin/magick -background none "$ICON_SOURCE" -resize "${size}x${size}" "$ICONSET/$filename"
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$ICON_FILE"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Codex Guardian</string>
  <key>CFBundleIconFile</key>
  <string>CodexGuardian</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --build-only|build-only)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2
    exit 2
    ;;
esac
