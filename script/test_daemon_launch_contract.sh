#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT_DIR/support/com.moni.codexguardian.daemon.plist"
INSTALLER="$ROOT_DIR/script/install_production.sh"

/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:5' "$PLIST" | /usr/bin/grep -Fxq -- '--socket'
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:6' "$PLIST" | /usr/bin/grep -Fxq '__GUARDIAN_SOCKET_PATH__'
if /usr/libexec/PlistBuddy -c 'Print :Sockets' "$PLIST" >/dev/null 2>&1; then
  /bin/echo 'production daemon must own its socket' >&2
  exit 1
fi
/usr/bin/grep -Fq 'Set :ProgramArguments:6 $SOCKET_PATH' "$INSTALLER"

/bin/echo 'Daemon launch contract test passed'
