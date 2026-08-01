#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
report="$repo_root/docs/MASTER_CONFIG_AGENT_FAILURE_REPORT.md"

if [[ ! -f "$report" ]]; then
  echo "FAIL: missing Master Config handoff: $report" >&2
  exit 1
fi

required_text=(
  "# Master Config Handoff: Agent Activity Substitution and Authorization Failure"
  "## Executive finding"
  "## Concrete incident evidence"
  "## Root causes"
  "## Required Master Config rules"
  "## Orchestration enforcement"
  "## Regression scenarios"
  "## Paste-ready Master Config block"
  "OUTCOME: WORKS | DOES NOT WORK | NOT PROVEN"
  "After a mandatory feasibility gate fails, dependent work stops."
  "Plans, goals, specifications, and documentation never authorize external writes."
  "6,205,812"
  "39,901"
  "357"
  "5092219499"
  "Do not install its former enforcement controls."
  "custom native approval hook and mandatory task"
  "Use standard Codex/Claude permissions."
)

for expected in "${required_text[@]}"; do
  if ! grep -Fq "$expected" "$report"; then
    echo "FAIL: report missing required text: $expected" >&2
    exit 1
  fi
done

echo "PASS: Master Config handoff preserves evidence and retires custom prompts"
