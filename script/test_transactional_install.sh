#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/guardian_install.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guardian-install-test.XXXXXX")"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

make_bundle() {
  local path="$1"
  local value="$2"
  /bin/mkdir -p "$path/Contents"
  printf '%s\n' "$value" > "$path/Contents/version"
}

verify_new() {
  /usr/bin/grep -Fxq new "$1/Contents/version"
}

activate_ok() { return 0; }
activate_fail() { return 1; }

SOURCE="$TEST_ROOT/source/Codex Guardian.app"
DEST="$TEST_ROOT/Applications/Codex Guardian.app"
BACKUPS="$TEST_ROOT/backups"
/bin/mkdir -p "$(/usr/bin/dirname "$DEST")"
make_bundle "$SOURCE" new
make_bundle "$DEST" old

guardian_install_bundle_transaction "$SOURCE" "$DEST" "$BACKUPS" verify_new activate_ok
/usr/bin/grep -Fxq new "$DEST/Contents/version"
SUCCESS_BACKUP="$(/usr/bin/find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | /usr/bin/head -1)"
test -n "$SUCCESS_BACKUP"
/usr/bin/grep -Fxq old "$SUCCESS_BACKUP/Contents/version"

/bin/rm -rf "$SOURCE"
make_bundle "$SOURCE" newer
if guardian_install_bundle_transaction "$SOURCE" "$DEST" "$BACKUPS" verify_new activate_ok; then
  /bin/echo "verification failure unexpectedly installed" >&2
  exit 1
fi
/usr/bin/grep -Fxq new "$DEST/Contents/version"

/bin/rm -rf "$SOURCE"
make_bundle "$SOURCE" new
if guardian_install_bundle_transaction "$SOURCE" "$DEST" "$BACKUPS" verify_new activate_fail; then
  /bin/echo "activation failure unexpectedly installed" >&2
  exit 1
fi
/usr/bin/grep -Fxq new "$DEST/Contents/version"
FAILED_CANDIDATE="$(/usr/bin/find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '*.failed' | /usr/bin/head -1)"
test -n "$FAILED_CANDIDATE"

STATE="$TEST_ROOT/Library/Application Support/CodexGuardian"
PLIST="$TEST_ROOT/Library/LaunchAgents/com.moni.codexguardian.plist"
/bin/mkdir -p "$STATE" "$(/usr/bin/dirname "$PLIST")"
printf 'journal\n' > "$STATE/guardian.sqlite"
printf 'plist\n' > "$PLIST"
UNINSTALL_ARCHIVE="$TEST_ROOT/uninstalled"
guardian_archive_runtime_files "$UNINSTALL_ARCHIVE" "$DEST" "$PLIST"
test ! -e "$DEST"
test ! -e "$PLIST"
test -f "$STATE/guardian.sqlite"
test -d "$UNINSTALL_ARCHIVE"

/bin/echo "Transactional install regression passed"
