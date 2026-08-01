#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_BINARY="${CODEX_GUARDIAN_MCP_BINARY:-$ROOT_DIR/dist/bin/codex-guardian-mcp}"

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
grep -q '"name":"guardian_status"' <<<"$OUTPUT"
grep -q '"name":"recover_agent"' <<<"$OUTPUT"
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
grep -q 'every unrelated observed task is idle' <<<"$OUTPUT"
grep -q 'Native recovery has no heartbeat automation to delete' <<<"$OUTPUT"
if grep -q 'delete or pause' <<<"$OUTPUT"; then
  echo "MCP permits stale paused recovery heartbeats" >&2
  exit 1
fi
if grep -q 'cannot submit a new turn automatically\|prompt copied' <<<"$OUTPUT"; then
  echo "MCP still exposes copy-only hard recovery" >&2
  exit 1
fi
if grep -q '"required":\["origin_token","recovery_prompt"\]' <<<"$OUTPUT"; then
  echo "MCP still requires a manually written recovery prompt" >&2
  exit 1
fi

FIXTURE_ROOT="$(mktemp -d)"
DAEMON_PID=""
cleanup() {
  if [[ -n "$DAEMON_PID" ]]; then
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT
SESSIONS_ROOT="$FIXTURE_ROOT/sessions"
STATE_ROOT="$FIXTURE_ROOT/state"
AUTOMATIONS_ROOT="$FIXTURE_ROOT/automations"
ORIGIN_TOKEN="31A25291-BDB6-44EF-AAB8-A95450F99A91"
THREAD_ID="019f0000-0000-7000-8000-000000000099"
NATIVE_ORIGIN_TOKEN="D0EB594A-25C6-43B5-A1C7-7AB151DF1A21"
NATIVE_THREAD_ID="019f0000-0000-7000-8000-000000000100"
mkdir -p "$SESSIONS_ROOT/2026/07/25"
printf '%s\n' \
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$THREAD_ID\"}}" \
  "{\"type\":\"event_msg\",\"payload\":{\"message\":\"prepare recovery $ORIGIN_TOKEN\"}}" \
  > "$SESSIONS_ROOT/2026/07/25/recovery.jsonl"
printf '%s\n' \
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$NATIVE_THREAD_ID\"}}" \
  "{\"type\":\"event_msg\",\"payload\":{\"message\":\"recover agent $NATIVE_ORIGIN_TOKEN\"}}" \
  > "$SESSIONS_ROOT/2026/07/25/native-recovery.jsonl"

DAEMON_BINARY="${CODEX_GUARDIAN_DAEMON_BINARY:-$ROOT_DIR/dist/CodexGuardian.app/Contents/SharedSupport/guardian-daemon}"
test -x "$DAEMON_BINARY"
mkdir -p "$STATE_ROOT/credentials"
chmod 700 "$STATE_ROOT" "$STATE_ROOT/credentials"
/usr/bin/openssl rand -out "$STATE_ROOT/credentials/mcp.token" 32
chmod 600 "$STATE_ROOT/credentials/mcp.token"
"$DAEMON_BINARY" --state-dir "$STATE_ROOT" --socket "$STATE_ROOT/guardian.sock" --once &
DAEMON_PID="$!"
for _ in {1..100}; do
  [[ -S "$STATE_ROOT/guardian.sock" ]] && break
  sleep 0.02
done
test -S "$STATE_ROOT/guardian.sock"

STATUS_OUTPUT="$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"guardian_status","arguments":{}}}'
} | CODEX_GUARDIAN_DAEMON_STATE_DIR="$STATE_ROOT" \
    CODEX_GUARDIAN_EXPECTED_DAEMON_PATH="$DAEMON_BINARY" "$MCP_BINARY")"
wait "$DAEMON_PID"
DAEMON_PID=""
grep -q '\"state\":\"connected\"' <<<"$STATUS_OUTPUT"
grep -q '\"authority\":\"shadow_only\"' <<<"$STATUS_OUTPUT"

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

NATIVE_OUTPUT="$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"recover_agent\",\"arguments\":{\"origin_token\":\"$NATIVE_ORIGIN_TOKEN\",\"recovery_prompt\":\"Continue native recovery.\"}}}"
} | CODEX_GUARDIAN_SESSIONS_DIR="$SESSIONS_ROOT" CODEX_GUARDIAN_STATE_DIR="$STATE_ROOT" "$MCP_BINARY")"

grep -q '\"state\":\"queued_native\"' <<<"$NATIVE_OUTPUT"
grep -q "\\\"thread_id\\\":\\\"$NATIVE_THREAD_ID\\\"" <<<"$NATIVE_OUTPUT"
NATIVE_REQUEST_FILE="$(/usr/bin/grep -l "$NATIVE_ORIGIN_TOKEN" "$STATE_ROOT"/pending/*.json)"
/usr/bin/grep -q '"requestMode":"nativeFirst"' "$NATIVE_REQUEST_FILE"
if /usr/bin/grep -q 'continuationAutomationID' "$NATIVE_REQUEST_FILE"; then
  echo "native recovery incorrectly requires a heartbeat automation" >&2
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
