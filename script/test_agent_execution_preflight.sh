#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
preflight="$repo_root/script/agent_execution_preflight.sh"
runtime_regression="$repo_root/script/test_agent_execution_runtime.sh"

if [[ ! -f "$preflight" ]]; then
  echo "MISSING: script/agent_execution_preflight.sh" >&2
  exit 1
fi

if bash "$preflight" phase passed 0 1 >/dev/null 2>&1; then
  echo "FAIL: insecure stateless phase API remains enabled" >&2
  exit 1
fi

if bash "$preflight" --state /tmp/does-not-exist status >/dev/null 2>&1; then
  echo "FAIL: missing execution state did not fail closed" >&2
  exit 1
fi

bash "$runtime_regression"
echo "Agent execution preflight regression: PASS"
