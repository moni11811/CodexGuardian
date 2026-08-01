#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/guardian_credentials.sh"
source "$ROOT_DIR/script/lib/guardian_install.sh"
SOURCE_APP="$ROOT_DIR/dist/CodexGuardian.app"
INSTALL_APP="/Applications/Codex Guardian.app"
LAUNCH_AGENT_SOURCE="$ROOT_DIR/support/com.moni.codexguardian.plist"
LAUNCH_AGENT_DEST="$HOME/Library/LaunchAgents/com.moni.codexguardian.plist"
DAEMON_LAUNCH_AGENT_SOURCE="$ROOT_DIR/support/com.moni.codexguardian.daemon.plist"
DAEMON_LAUNCH_AGENT_DEST="$HOME/Library/LaunchAgents/com.moni.codexguardian.daemon.plist"
STATE_DIR="$HOME/Library/Application Support/CodexGuardian"
CREDENTIAL_DIR="$STATE_DIR/credentials"
SOCKET_PATH="$STATE_DIR/guardian.sock"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/com.moni.codexguardian"
DAEMON_SERVICE="$DOMAIN/com.moni.codexguardian.daemon"

BACKUP_DIR="$HOME/Library/Application Support/CodexGuardian-Backups"
CONFIG_STAGE=""
CONFIG_BACKUP=""
PREVIOUS_UI_PLIST=0
PREVIOUS_DAEMON_PLIST=0

guardian_verify_candidate() {
  local candidate="$1"
  /usr/bin/xattr -cr "$candidate"
  /usr/bin/codesign --force --sign - "$candidate/Contents/SharedSupport/codex-guardian-mcp"
  /usr/bin/codesign --force --sign - "$candidate/Contents/SharedSupport/guardian-daemon"
  /usr/bin/codesign --force --sign - "$candidate/Contents/SharedSupport/guardianctl"
  /usr/bin/codesign --force --deep --sign - "$candidate"
  /usr/bin/codesign --verify --deep --strict "$candidate"
}

guardian_activate_candidate() {
  local candidate="$1"
  test -x "$candidate/Contents/MacOS/CodexGuardian" || return 1
  /bin/cp "$CONFIG_STAGE/com.moni.codexguardian.plist" "$LAUNCH_AGENT_DEST.new" || return 1
  /bin/cp "$CONFIG_STAGE/com.moni.codexguardian.daemon.plist" "$DAEMON_LAUNCH_AGENT_DEST.new" || return 1
  /bin/chmod 600 "$LAUNCH_AGENT_DEST.new" "$DAEMON_LAUNCH_AGENT_DEST.new" || return 1
  /bin/mv -f "$LAUNCH_AGENT_DEST.new" "$LAUNCH_AGENT_DEST" || return 1
  /bin/mv -f "$DAEMON_LAUNCH_AGENT_DEST.new" "$DAEMON_LAUNCH_AGENT_DEST" || return 1

  /bin/launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  /bin/launchctl bootout "$DAEMON_SERVICE" >/dev/null 2>&1 || true
  /usr/bin/pkill -x CodexGuardian >/dev/null 2>&1 || true
  /usr/bin/pkill -x guardian-daemon >/dev/null 2>&1 || true
  /usr/bin/unlink "$SOCKET_PATH" >/dev/null 2>&1 || true
  if ! /bin/launchctl bootstrap "$DOMAIN" "$DAEMON_LAUNCH_AGENT_DEST"; then
    /bin/echo "Activation failed: daemon bootstrap" >&2
    return 1
  fi
  if ! /bin/launchctl kickstart -k "$DAEMON_SERVICE"; then
    /bin/echo "Activation failed: daemon kickstart" >&2
    return 1
  fi
  if ! /bin/launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT_DEST"; then
    /bin/echo "Activation failed: UI bootstrap" >&2
    return 1
  fi
  if ! /bin/launchctl kickstart -k "$SERVICE"; then
    /bin/echo "Activation failed: UI kickstart" >&2
    return 1
  fi

  local attempt=0
  while [[ "$attempt" -lt 50 ]]; do
    if "$candidate/Contents/SharedSupport/guardianctl" >/dev/null 2>&1; then
      /bin/launchctl print "$DAEMON_SERVICE" >/dev/null 2>&1 || return 1
      return 0
    fi
    attempt=$((attempt + 1))
    /bin/sleep 0.1
  done
  /bin/echo "Activation failed: daemon health check" >&2
  return 1
}

guardian_restore_previous() {
  /bin/launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  /bin/launchctl bootout "$DAEMON_SERVICE" >/dev/null 2>&1 || true
  /usr/bin/pkill -x CodexGuardian >/dev/null 2>&1 || true
  /usr/bin/pkill -x guardian-daemon >/dev/null 2>&1 || true
  /usr/bin/unlink "$SOCKET_PATH" >/dev/null 2>&1 || true

  if [[ "$PREVIOUS_UI_PLIST" -eq 1 ]]; then
    /bin/cp "$CONFIG_BACKUP/com.moni.codexguardian.plist" "$LAUNCH_AGENT_DEST"
  else
    /bin/rm -f "$LAUNCH_AGENT_DEST"
  fi
  if [[ "$PREVIOUS_DAEMON_PLIST" -eq 1 ]]; then
    /bin/cp "$CONFIG_BACKUP/com.moni.codexguardian.daemon.plist" "$DAEMON_LAUNCH_AGENT_DEST"
  else
    /bin/rm -f "$DAEMON_LAUNCH_AGENT_DEST"
  fi

  if [[ -x "$INSTALL_APP/Contents/MacOS/CodexGuardian" ]]; then
    if [[ -f "$DAEMON_LAUNCH_AGENT_DEST" ]]; then
      /bin/launchctl bootstrap "$DOMAIN" "$DAEMON_LAUNCH_AGENT_DEST" >/dev/null 2>&1 || true
    fi
    if [[ -f "$LAUNCH_AGENT_DEST" ]]; then
      /bin/launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT_DEST" >/dev/null 2>&1 || true
    fi
  fi
}

CODEX_GUARDIAN_BUILD_CONFIGURATION=release \
  "$ROOT_DIR/script/build_and_run.sh" --build-only

test ! -L "$STATE_DIR"
test ! -L "$CREDENTIAL_DIR"
mkdir -p "$HOME/Library/LaunchAgents" "$CREDENTIAL_DIR"
chmod 700 "$STATE_DIR" "$CREDENTIAL_DIR"
umask 077
for credential in mac-ui.token mcp.token cli.token; do
  guardian_require_credential "$CREDENTIAL_DIR/$credential"
done

/bin/mkdir -p "$BACKUP_DIR"
/bin/chmod 700 "$BACKUP_DIR"
CONFIG_STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/guardian-config-stage.XXXXXX")"
trap '/bin/rm -rf "$CONFIG_STAGE"' EXIT
CONFIG_BACKUP="$BACKUP_DIR/$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}.config"
/bin/mkdir -p "$CONFIG_BACKUP"
/bin/chmod 700 "$CONFIG_BACKUP"
/bin/cp "$LAUNCH_AGENT_SOURCE" "$CONFIG_STAGE/com.moni.codexguardian.plist"
/bin/cp "$DAEMON_LAUNCH_AGENT_SOURCE" "$CONFIG_STAGE/com.moni.codexguardian.daemon.plist"
/usr/libexec/PlistBuddy \
  -c "Set :ProgramArguments:2 HOME=$HOME" \
  "$CONFIG_STAGE/com.moni.codexguardian.plist"
/usr/libexec/PlistBuddy \
  -c "Set :ProgramArguments:2 HOME=$HOME" \
  -c "Set :ProgramArguments:6 $SOCKET_PATH" \
  "$CONFIG_STAGE/com.moni.codexguardian.daemon.plist"
/usr/bin/plutil -lint "$CONFIG_STAGE/com.moni.codexguardian.plist" >/dev/null
/usr/bin/plutil -lint "$CONFIG_STAGE/com.moni.codexguardian.daemon.plist" >/dev/null
if [[ -f "$LAUNCH_AGENT_DEST" ]]; then
  PREVIOUS_UI_PLIST=1
  /bin/cp "$LAUNCH_AGENT_DEST" "$CONFIG_BACKUP/com.moni.codexguardian.plist"
fi
if [[ -f "$DAEMON_LAUNCH_AGENT_DEST" ]]; then
  PREVIOUS_DAEMON_PLIST=1
  /bin/cp "$DAEMON_LAUNCH_AGENT_DEST" "$CONFIG_BACKUP/com.moni.codexguardian.daemon.plist"
fi
guardian_install_bundle_transaction \
  "$SOURCE_APP" \
  "$INSTALL_APP" \
  "$BACKUP_DIR" \
  guardian_verify_candidate \
  guardian_activate_candidate \
  guardian_restore_previous

/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/plutil -lint "$LAUNCH_AGENT_DEST" >/dev/null
/usr/bin/plutil -lint "$DAEMON_LAUNCH_AGENT_DEST" >/dev/null

printf '%s\n' "Installed $INSTALL_APP"
