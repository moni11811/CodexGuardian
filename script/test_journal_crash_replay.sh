#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/guardian-journal-crash.XXXXXX")"
BUILD_LOG="$HARNESS_DIR/build.log"

cleanup() {
  case "$HARNESS_DIR" in
    "${TMPDIR:-/tmp}"/guardian-journal-crash.*)
      /bin/rm -rf -- "$HARNESS_DIR"
      ;;
  esac
}
trap cleanup EXIT

if ! swift build --package-path "$REPO_ROOT" --product guardian-journal-crash-worker >"$BUILD_LOG" 2>&1; then
  /usr/bin/tail -40 "$BUILD_LOG" >&2
  exit 1
fi

BIN_DIR="$(swift build --package-path "$REPO_ROOT" --show-bin-path)"
WORKER="$BIN_DIR/guardian-journal-crash-worker"
test -x "$WORKER"

wait_for_commit_marker() {
  local pid="$1"
  local marker="$2"
  local attempt

  for attempt in {1..200}; do
    if [[ -f "$marker" ]]; then
      return 0
    fi
    if ! /bin/kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      printf 'writer exited before commit marker: %s\n' "$marker" >&2
      return 1
    fi
    /bin/sleep 0.05
  done

  /bin/kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  printf 'timed out waiting for commit marker: %s\n' "$marker" >&2
  return 1
}

crash_and_verify() {
  local scenario="$1"
  local operation_id="$2"
  local scenario_dir="$HARNESS_DIR/$scenario"
  local database="$scenario_dir/guardian.sqlite"
  local marker="$scenario_dir/commit.ready"
  local pid
  local status

  /bin/mkdir -p "$scenario_dir"
  "$WORKER" write "$database" "$scenario" "$operation_id" "$marker" &
  pid=$!
  wait_for_commit_marker "$pid" "$marker"

  /bin/kill -KILL "$pid"
  set +e
  wait "$pid" 2>/dev/null
  status=$?
  set -e
  if [[ "$status" -ne 137 ]]; then
    printf 'writer was not killed by SIGKILL: scenario=%s status=%s\n' "$scenario" "$status" >&2
    return 1
  fi

  "$WORKER" verify "$database" "$scenario" "$operation_id"
}

SCENARIOS=(
  authority-prepared
  authority-activated
  rollback-authority-prepare
  rollback-authority-activate
  native-prepared
  native-target-loaded
  native-continuation-sent
  native-delivery-attempt
  native-delivery-receipt
  native-monitoring
  native-waiting-user
  native-acknowledged
  native-failed
  native-timed-out
  native-dead-letter
  hard-prepared
  hard-gated
  hard-restart-issued
  hard-desktop-started
  hard-control-ready
  hard-target-loaded
  rollback-create
  rollback-transition
  rollback-outbox-enqueue
  rollback-receipt
  rollback-ack
  rollback-remote-pairing
  rollback-remote-acceptance
  rollback-remote-queue
  rollback-remote-revocation
  rollback-remote-completion
  rollback-remote-claim
  rollback-remote-prepare
  rollback-remote-invoke
  rollback-remote-ack
  remote-command-accepted
  rollback-daemon-event
)

index=1
for scenario in "${SCENARIOS[@]}"; do
  operation_id="$(printf '00000000-0000-0000-0000-%012d' "$index")"
  crash_and_verify "$scenario" "$operation_id"
  index=$((index + 1))
done

printf '%s\n' 'Journal crash/reopen replay test passed'
