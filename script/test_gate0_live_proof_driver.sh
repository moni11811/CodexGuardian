#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
driver="$repo_root/script/Gate0LiveProof.swift"

if [[ ! -f "$driver" ]]; then
  echo "FAIL: missing Gate0LiveProof.swift"
  exit 1
fi

/usr/bin/grep -q 'CodexAppServerRecoveryCoordinator' "$driver"
/usr/bin/grep -q 'GUARDIAN_GATE0_MARKER' "$driver"
/usr/bin/grep -q 'GUARDIAN_GATE0_ACK' "$driver"
/usr/bin/grep -q 'CommandLine.arguments.count == 4' "$driver"
/usr/bin/grep -q 'CodexGuardianGate0Trace' "$driver"
/usr/bin/grep -q 'trace_path' "$driver"

if /usr/bin/grep -Eq 'restart_codex|codex exec resume' "$driver"; then
  echo "FAIL: live proof must not restart or launch detached resume"
  exit 1
fi

binary="$(mktemp -t codex-guardian-gate0-live.XXXXXX)"
trap '/bin/rm -f "$binary"' EXIT

/usr/bin/swiftc \
  "$repo_root/Sources/GuardianCore/CodexAppServerRecoveryProtocol.swift" \
  "$repo_root/Sources/GuardianCore/CodexAppServerRecoveryCoordinator.swift" \
  "$repo_root/Sources/GuardianCore/CodexAppServerRecoveryLiveness.swift" \
  "$repo_root/Sources/GuardianCore/CodexAppServerStdioTransport.swift" \
  "$driver" \
  -o "$binary"

set +e
usage_output="$($binary 2>/dev/null)"
usage_status=$?
set -e

if [[ $usage_status -ne 64 ]] || [[ "$usage_output" != *'"reason":"usage"'* ]]; then
  echo "FAIL: compiled driver did not reject missing arguments"
  exit 1
fi

echo "PASS: Gate 0 live proof driver contract"
