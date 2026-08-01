#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/guardian_credentials.sh"

FIXTURE_ROOT="$(mktemp -d)"
trap '/bin/rm -rf "$FIXTURE_ROOT"' EXIT
chmod 700 "$FIXTURE_ROOT"

BAD="$FIXTURE_ROOT/bad.token"
/bin/dd if=/dev/zero of="$BAD" bs=31 count=1 status=none
chmod 600 "$BAD"
if guardian_require_credential "$BAD"; then
  echo "accepted malformed existing credential" >&2
  exit 1
fi
test "$(stat -f %z "$BAD")" = 31

GOOD="$FIXTURE_ROOT/good.token"
guardian_require_credential "$GOOD"
test "$(stat -f %z "$GOOD")" = 32
test "$(stat -f %Lp "$GOOD")" = 600

LINK="$FIXTURE_ROOT/link.token"
ln -s "$GOOD" "$LINK"
if guardian_require_credential "$LINK"; then
  echo "accepted credential symlink" >&2
  exit 1
fi

echo "Credential provisioning regression passed"
