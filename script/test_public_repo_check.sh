#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/guardian-public-check.XXXXXX")"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

/usr/bin/git -C "$TEST_ROOT" init -q
/bin/mkdir -p "$TEST_ROOT/script"
/bin/cp "$ROOT_DIR/script/check_public_repo.sh" "$TEST_ROOT/script/check_public_repo.sh"
/bin/chmod +x "$TEST_ROOT/script/check_public_repo.sh"
/usr/bin/git -C "$TEST_ROOT" add script/check_public_repo.sh

"$TEST_ROOT/script/check_public_repo.sh" >/dev/null

/usr/bin/printf 'ghp_%s\n' '123456789012345678901234567890' > "$TEST_ROOT/leak.txt"
if "$TEST_ROOT/script/check_public_repo.sh" >/dev/null 2>&1; then
  /bin/echo 'public checker accepted a credential pattern' >&2
  exit 1
fi

/bin/rm "$TEST_ROOT/leak.txt"
/usr/bin/printf 'temporary\n' > "$TEST_ROOT/deleted.txt"
/usr/bin/git -C "$TEST_ROOT" add deleted.txt
/bin/rm "$TEST_ROOT/deleted.txt"
"$TEST_ROOT/script/check_public_repo.sh" >/dev/null

/bin/echo 'Public repository checker regression passed'
