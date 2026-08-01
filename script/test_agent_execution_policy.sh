#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
policy_file="$repo_root/AGENTS.md"

required_rules=(
  "## Outcome-first execution guard"
  "After a feasibility gate fails, stop downstream implementation."
  "Status must lead with whether the requested user-visible outcome works now."
  "Research, scaffolding, test counts, and documentation are not the deliverable unless the user requested them."
  "After three bounded tool or research rounds without movement toward the user-visible outcome, stop and re-evaluate the route."
  "ClosedDexter adds no custom"
  "allow/deny dialogs, PreToolUse permission broker, or mandatory task ledger."
)

missing=0
for rule in "${required_rules[@]}"; do
  if ! rg --fixed-strings --quiet "$rule" "$policy_file"; then
    echo "MISSING: $rule" >&2
    missing=1
  fi
done

for forbidden in "native host approval" "One immutable per-task execution state is mandatory." "the installed PreToolUse interceptor"; do
  if rg --fixed-strings --quiet "$forbidden" "$policy_file"; then
    echo "FORBIDDEN: $forbidden" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "Agent execution policy regression: FAIL" >&2
  exit 1
fi

echo "Agent execution policy regression: PASS"
