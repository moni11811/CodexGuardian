#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_BINARY="$ROOT_DIR/dist/bin/codex-guardian-mcp"

if [[ ! -x "$MCP_BINARY" ]]; then
  echo "MCP binary missing; run ./script/build_and_run.sh first" >&2
  exit 1
fi

OUTPUT="$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
} | "$MCP_BINARY")"

grep -q '"name":"codex-guardian"' <<<"$OUTPUT"
grep -q '"name":"restart_codex"' <<<"$OUTPUT"
grep -q '"origin_token"' <<<"$OUTPUT"
grep -q '"required":\["origin_token"\]' <<<"$OUTPUT"
grep -q 'sanitized recent task state' <<<"$OUTPUT"
if grep -q '"required":\["origin_token","recovery_prompt"\]' <<<"$OUTPUT"; then
  echo "MCP still requires a manually written recovery prompt" >&2
  exit 1
fi
echo "MCP smoke test passed"
