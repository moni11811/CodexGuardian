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
grep -q '"name":"prepare_restart"' <<<"$OUTPUT"
grep -q '"outputSchema"' <<<"$OUTPUT"
grep -q '"name":"restart_codex"' <<<"$OUTPUT"
grep -q '"name":"recovery_tick"' <<<"$OUTPUT"
grep -q '"name":"ack_recovery"' <<<"$OUTPUT"
grep -q '"origin_token"' <<<"$OUTPUT"
grep -q '"required":\["origin_token"\]' <<<"$OUTPUT"
grep -q '"required":\["origin_token","continuation_automation_id"\]' <<<"$OUTPUT"
grep -q 'sanitized recent task state' <<<"$OUTPUT"
grep -q 'codex_app__send_message_to_thread' <<<"$OUTPUT"
grep -q 'heartbeat continues the exact task after relaunch' <<<"$OUTPUT"
grep -q 'every observed task is idle and quiet' <<<"$OUTPUT"
if grep -q 'cannot submit a new turn automatically\|prompt copied' <<<"$OUTPUT"; then
  echo "MCP still exposes copy-only hard recovery" >&2
  exit 1
fi
if grep -q '"required":\["origin_token","recovery_prompt"\]' <<<"$OUTPUT"; then
  echo "MCP still requires a manually written recovery prompt" >&2
  exit 1
fi

FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT
SESSIONS_ROOT="$FIXTURE_ROOT/sessions"
STATE_ROOT="$FIXTURE_ROOT/state"
AUTOMATIONS_ROOT="$FIXTURE_ROOT/automations"
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

PREPARE_RESTART_OUTPUT="$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"prepare_restart\",\"arguments\":{\"origin_token\":\"$ORIGIN_TOKEN\"}}}"
} | CODEX_GUARDIAN_SESSIONS_DIR="$SESSIONS_ROOT" CODEX_GUARDIAN_STATE_DIR="$STATE_ROOT" "$MCP_BINARY")"

grep -q "\\\"thread_id\\\":\\\"$THREAD_ID\\\"" <<<"$PREPARE_RESTART_OUTPUT"
grep -q '\"heartbeat_prompt\"' <<<"$PREPARE_RESTART_OUTPUT"
grep -q "$ORIGIN_TOKEN" <<<"$PREPARE_RESTART_OUTPUT"

AUTOMATION_ID="guardian-recovery-smoke"
mkdir -p "$AUTOMATIONS_ROOT/$AUTOMATION_ID"
printf '%s\n' \
  'version = 1' \
  "id = \"$AUTOMATION_ID\"" \
  'kind = "heartbeat"' \
  'status = "ACTIVE"' \
  "target_thread_id = \"$THREAD_ID\"" \
  "prompt = \"Call recovery_tick with $ORIGIN_TOKEN\"" \
  'rrule = "RRULE:FREQ=MINUTELY;INTERVAL=1"' \
  > "$AUTOMATIONS_ROOT/$AUTOMATION_ID/automation.toml"

RESTART_OUTPUT="$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"restart_codex\",\"arguments\":{\"origin_token\":\"$ORIGIN_TOKEN\",\"continuation_automation_id\":\"$AUTOMATION_ID\"}}}"
} | CODEX_GUARDIAN_SESSIONS_DIR="$SESSIONS_ROOT" CODEX_GUARDIAN_STATE_DIR="$STATE_ROOT" CODEX_GUARDIAN_AUTOMATIONS_DIR="$AUTOMATIONS_ROOT" "$MCP_BINARY")"

grep -q '\"state\":\"queued\"' <<<"$RESTART_OUTPUT"
grep -q "$AUTOMATION_ID" <<<"$RESTART_OUTPUT"
find "$STATE_ROOT/pending" -type f -name '*.json' -print -quit | grep -q .

TICK_OUTPUT="$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"recovery_tick\",\"arguments\":{\"origin_token\":\"$ORIGIN_TOKEN\"}}}"
} | CODEX_GUARDIAN_STATE_DIR="$STATE_ROOT" CODEX_GUARDIAN_AUTOMATIONS_DIR="$AUTOMATIONS_ROOT" "$MCP_BINARY")"

grep -q '\"state\":\"waiting\"' <<<"$TICK_OUTPUT"
grep -q 'heartbeat_registered' <<<"$TICK_OUTPUT"
grep -q 'heartbeatObservedAt' "$STATE_ROOT"/pending/*.json
echo "MCP smoke test passed"
