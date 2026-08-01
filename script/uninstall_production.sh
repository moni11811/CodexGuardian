#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/guardian_install.sh"

INSTALL_APP="${GUARDIAN_INSTALL_APP:-/Applications/Codex Guardian.app}"
LAUNCH_AGENT_DIR="${GUARDIAN_LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}"
STATE_DIR="${GUARDIAN_STATE_DIR:-$HOME/Library/Application Support/CodexGuardian}"
ARCHIVE_ROOT="${GUARDIAN_UNINSTALL_ARCHIVE:-$HOME/Library/Application Support/CodexGuardian-Uninstalled}"
DOMAIN="gui/$(id -u)"

/bin/launchctl bootout "$DOMAIN/com.moni.codexguardian" >/dev/null 2>&1 || true
/bin/launchctl bootout "$DOMAIN/com.moni.codexguardian.daemon" >/dev/null 2>&1 || true
/usr/bin/pkill -x CodexGuardian >/dev/null 2>&1 || true
/usr/bin/pkill -x guardian-daemon >/dev/null 2>&1 || true

guardian_archive_runtime_files \
  "$ARCHIVE_ROOT" \
  "$INSTALL_APP" \
  "$LAUNCH_AGENT_DIR/com.moni.codexguardian.plist" \
  "$LAUNCH_AGENT_DIR/com.moni.codexguardian.daemon.plist"

if [[ "${1:-}" == "--purge-state" ]]; then
  if [[ "$STATE_DIR" != /* || "$STATE_DIR" == "/" || -L "$STATE_DIR" ]]; then
    /bin/echo "Refusing unsafe state purge" >&2
    exit 65
  fi
  guardian_archive_runtime_files "$ARCHIVE_ROOT" "$STATE_DIR"
fi

/bin/echo "Guardian runtime archived. State preserved unless --purge-state was supplied."
