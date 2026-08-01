#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
control="$repo_root/script/agent_execution_preflight.sh"
state_dir="$(mktemp -d)"
state="$state_dir/execution.json"
payload_digest="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
trap 'rm -rf "$state_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expect_allowed() {
  local label="$1"
  shift
  if ! bash "$control" --state "$state" "$@" >"$state_dir/stdout" 2>"$state_dir/stderr"; then
    echo "EXPECTED ALLOW: $label" >&2
    cat "$state_dir/stderr" >&2
    exit 1
  fi
}

expect_denied() {
  local label="$1"
  shift
  if bash "$control" --state "$state" "$@" >"$state_dir/stdout" 2>"$state_dir/stderr"; then
    echo "EXPECTED DENY: $label" >&2
    cat "$state_dir/stdout" >&2
    exit 1
  fi
}

expect_stdout_first_line() {
  local label="$1"
  local expected="$2"
  shift 2
  expect_allowed "$label" "$@"
  local actual
  actual="$(head -n 1 "$state_dir/stdout")"
  [[ "$actual" == "$expected" ]] ||
    fail "$label: expected '$expected', got '$actual'"
}

expect_allowed "initialize one outcome and mandatory live gate" \
  init \
  --outcome "Restart and continue the exact live Codex Desktop task" \
  --direct-proof "Observed exact-task continuation after restart" \
  --gate gate-0 \
  --required-evidence live \
  --turn turn-8 \
  --max-no-progress-rounds 3 \
  --max-fallbacks 1 \
  --max-tokens 1000 \
  --max-elapsed-seconds 600

expect_allowed "component evidence is recorded with narrow scope" \
  evidence add \
  --id component-suite \
  --type component \
  --claim "Recovery helper passes component tests" \
  --source "357 tests"

expect_denied "component evidence cannot pass a live gate" \
  gate pass \
  --gate gate-0 \
  --evidence component-suite

expect_stdout_first_line "component tests cannot manufacture success" \
  "OUTCOME: NOT PROVEN" \
  status

expect_allowed "failed critical gate is durable state" \
  gate fail \
  --gate gate-0 \
  --symptom "No supported same-Desktop control listener" \
  --evidence-boundary "Exact live read/write remains unproved"

expect_denied "stored failed gate blocks dependent phase despite caller intent" \
  phase request \
  --phase 2 \
  --depends-on gate-0

expect_allowed "worker inherits owner gate and forbidden phases" \
  delegate \
  --worker terra-1

expect_denied "worker cannot bypass failed owner gate" \
  phase request \
  --phase 2 \
  --depends-on gate-0 \
  --worker terra-1

expect_allowed "first failed action is learned with corrective requirements" \
  failure record \
  --id live-route-primary \
  --scope task-1/sol/context-mode \
  --action "Read exact live task" \
  --fingerprint primary-v1 \
  --classification deterministic \
  --symptom "Transport unavailable" \
  --inputs "same task id" \
  --environment "Codex Desktop" \
  --evidence-boundary "No live response" \
  --corrective-action "Use bounded native task transport" \
  --expected-evidence "Exact live response"

expect_denied "unchanged deterministic retry is forbidden" \
  attempt \
  --scope task-1/sol/context-mode \
  --action "Read exact live task" \
  --fingerprint primary-v1

expect_allowed "one materially changed fallback is permitted" \
  attempt \
  --scope task-1/sol/context-mode \
  --action "Read exact live task through native transport" \
  --fingerprint fallback-v2 \
  --fallback-of live-route-primary \
  --changed-variable transport

expect_allowed "failed fallback is learned" \
  failure record \
  --id live-route-fallback \
  --scope task-1/sol/context-mode \
  --action "Read exact live task through native transport" \
  --fingerprint fallback-v2 \
  --classification environment \
  --symptom "Native listener absent" \
  --inputs "same task id" \
  --environment "Codex Desktop" \
  --evidence-boundary "No live response" \
  --corrective-action "Stop route and report missing listener" \
  --expected-evidence "External capability change"

expect_denied "failed changed fallback ends the route" \
  attempt \
  --scope task-1/sol/context-mode \
  --action "Try another equivalent transport" \
  --fingerprint fallback-v3 \
  --fallback-of live-route-fallback \
  --changed-variable command

expect_denied "unmapped artifact is rejected" \
  artifact add \
  --path docs/substitute-progress.md \
  --exit-criterion ""

expect_allowed "waiting automation has an expiry" \
  wait register \
  --id recovery-heartbeat \
  --owner task-1 \
  --expires-at 100

expect_denied "waiting automation id cannot be duplicated" \
  wait register \
  --id recovery-heartbeat \
  --owner task-1 \
  --expires-at 200

expect_allowed "expired waiting automation is cleaned up" \
  wait cleanup \
  --now 101

expect_denied "expired automation no longer exists" \
  wait require \
  --id recovery-heartbeat \
  --owner task-1

for round in 1 2 3; do
  expect_allowed "record non-improving round $round" \
    progress record \
    --hypothesis "Listener may appear" \
    --action "Bounded liveness probe $round" \
    --result "No listener" \
    --changed-variable "probe-$round" \
    --stronger-evidence no
done

expect_denied "three non-improving rounds trip loss circuit" \
  progress record \
  --hypothesis "Listener may appear" \
  --action "Fourth equivalent probe" \
  --result "No listener" \
  --changed-variable "probe-4" \
  --stronger-evidence no

expect_denied "plan text cannot create external authorization" \
  authorize \
  --source plan \
  --turn turn-7 \
  --action delete-comment \
  --target openai/codex/issues/25914/comments/5092219499 \
  --payload-digest "$payload_digest" \
  --approval "Plan says file upstream"

expect_allowed "current-turn exact authorization is recorded" \
  authorize \
  --source current-user-turn \
  --turn turn-8 \
  --action delete-comment \
  --target openai/codex/issues/25914/comments/5092219499 \
  --payload-digest "$payload_digest" \
  --approval "Delete that exact comment"

expect_denied "authorization cannot mutate a different target" \
  external-write \
  --turn turn-8 \
  --action delete-comment \
  --target openai/codex/issues/25914/comments/other \
  --payload-digest "$payload_digest"

expect_allowed "exact authorization is single-use" \
  external-write \
  --turn turn-8 \
  --action delete-comment \
  --target openai/codex/issues/25914/comments/5092219499 \
  --payload-digest "$payload_digest"

expect_denied "used authorization cannot be replayed" \
  external-write \
  --turn turn-8 \
  --action delete-comment \
  --target openai/codex/issues/25914/comments/5092219499 \
  --payload-digest "$payload_digest"

expect_stdout_first_line "failed gate leads with user-visible truth" \
  "OUTCOME: DOES NOT WORK" \
  status

budget_state="$state_dir/budget.json"
bash "$control" --state "$budget_state" init \
  --outcome "Bounded task" \
  --direct-proof "Live bounded proof" \
  --gate gate-0 \
  --required-evidence live \
  --turn turn-budget \
  --max-tokens 1000 \
  --max-elapsed-seconds 600 \
  >"$state_dir/stdout" 2>"$state_dir/stderr" ||
  fail "initialize budget fixture"

bash "$control" --state "$budget_state" budget record \
  --tokens-total 1000 \
  --elapsed-seconds 600 \
  >"$state_dir/stdout" 2>"$state_dir/stderr" ||
  fail "record budget boundary"

if bash "$control" --state "$budget_state" delegate \
  --worker terra-after-budget \
  >"$state_dir/stdout" 2>"$state_dir/stderr"; then
  fail "hard loss budget did not block new work"
fi

echo "Agent execution runtime regression: PASS"
