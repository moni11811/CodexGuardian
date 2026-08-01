#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/script/install_production.sh"

for step in \
  "daemon bootstrap" \
  "daemon kickstart" \
  "UI bootstrap" \
  "UI kickstart" \
  "daemon health check"; do
  /usr/bin/grep -Fq "Activation failed: $step" "$INSTALL_SCRIPT"
done

/bin/echo "Install activation diagnostics test passed"
