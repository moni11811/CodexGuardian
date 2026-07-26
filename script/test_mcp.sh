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
grep -q '"name":"prepare_recovery"' <<<"$OUTPUT"
grep -q '"outputSchema"' <<<"$OUTPUT"
grep -q '"name":"restart_codex"' <<<"$OUTPUT"
grep -q '"origin_token"' <<<"$OUTPUT"
grep -q '"required":\["origin_token"\]' <<<"$OUTPUT"
grep -q 'sanitized recent task state' <<<"$OUTPUT"
grep -q 'codex_app__send_message_to_thread' <<<"$OUTPUT"
grep -q 'cannot submit a new turn automatically' <<<"$OUTPUT"
grep -q 'every observed Codex task is idle and quiet' <<<"$OUTPUT"
if grep -q '"required":\["origin_token","recovery_prompt"\]' <<<"$OUTPUT"; then
  echo "MCP still requires a manually written recovery prompt" >&2
  exit 1
fi

FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT
SESSIONS_ROOT="$FIXTURE_ROOT/sessions"
STATE_ROOT="$FIXTURE_ROOT/state"
ORIGIN_TOKEN="31A25291-BDB6-44EF-AAB8-A95450F99A91"
THREAD_ID="019f0000-0000-7000-8000-000000000099"
mkdir -p "$SESSIONS_ROOT/2026/07/25"
printf '%s\n' \
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$THREAD_ID\"}}" \
  "{\"type\":\"event_msg\",\"payload\":{\"message\":\"prepare recovery $ORIGIN_TOKEN\"}}" \
  > "$SESSIONS_ROOT/2026/07/25/recovery.jsonl"

PREPARE_OUTPUT="$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"prepare_recovery\",\"arguments\":{\"origin_token\":\"$ORIGIN_TOKEN\",\"recovery_prompt\":\"Use the fallback route.\"}}}"
} | CODEX_GUARDIAN_SESSIONS_DIR="$SESSIONS_ROOT" CODEX_GUARDIAN_STATE_DIR="$STATE_ROOT" "$MCP_BINARY")"

grep -q "\\\"thread_id\\\":\\\"$THREAD_ID\\\"" <<<"$PREPARE_OUTPUT"
grep -q '\\\"recovery_prompt\\\":\\\"Use the fallback route.\\\"' <<<"$PREPARE_OUTPUT"
grep -q '\\\"restarts_desktop\\\":false' <<<"$PREPARE_OUTPUT"
if find "$STATE_ROOT" -type f -name '*.json' -print -quit 2>/dev/null | grep -q .; then
  echo "prepare_recovery incorrectly queued a hard restart" >&2
  exit 1
fi
echo "MCP smoke test passed"
