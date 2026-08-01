#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/script/install_production.sh"

for plist in \
  "$ROOT_DIR/support/com.moni.codexguardian.plist" \
  "$ROOT_DIR/support/com.moni.codexguardian.daemon.plist"; do
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" | /usr/bin/grep -Fxq '/usr/bin/env'
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$plist" | /usr/bin/grep -Fxq -- '-i'
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$plist" | /usr/bin/grep -Fxq 'HOME=__GUARDIAN_HOME__'
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:3' "$plist" | /usr/bin/grep -Fxq 'PATH=/usr/bin:/bin:/usr/sbin:/sbin'
done

/usr/bin/grep -Fq 'Set :ProgramArguments:2 HOME=$HOME' "$INSTALLER"

/bin/echo 'Launch environment contract test passed'
