#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
INSTALL_SCRIPT="$ROOT_DIR/script/install_production.sh"

/usr/bin/grep -Fq 'CODEX_GUARDIAN_BUILD_CONFIGURATION=release' "$INSTALL_SCRIPT"
/usr/bin/grep -Fq 'swift build -c "$BUILD_CONFIGURATION"' "$BUILD_SCRIPT"
/usr/bin/grep -Fq 'if [[ "$MODE" != "--build-only" && "$MODE" != "build-only" ]]' "$BUILD_SCRIPT"

printf '%s\n' "Production build contract test passed"
