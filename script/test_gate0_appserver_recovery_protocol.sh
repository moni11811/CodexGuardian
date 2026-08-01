#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_file="$repo_root/Sources/GuardianCore/CodexAppServerRecoveryProtocol.swift"
coordinator_file="$repo_root/Sources/GuardianCore/CodexAppServerRecoveryCoordinator.swift"
transport_file="$repo_root/Sources/GuardianCore/CodexAppServerStdioTransport.swift"

if [[ ! -f "$source_file" ]]; then
  echo "FAIL: missing exact-thread app-server recovery protocol" >&2
  exit 1
fi

if [[ ! -f "$transport_file" ]]; then
  echo "FAIL: missing independent app-server stdio transport" >&2
  exit 1
fi

if [[ ! -f "$coordinator_file" ]]; then
  echo "FAIL: missing three-phase app-server recovery coordinator" >&2
  exit 1
fi

required_contract=(
  '"initialize"'
  '"initialized"'
  '"thread/resume"'
  '"thread/read"'
  '"includeTurns"'
  '"turn/start"'
  '"clientUserMessageId"'
  '"turn/completed"'
)

for expected in "${required_contract[@]}"; do
  if ! grep -Fq "$expected" "$source_file"; then
    echo "FAIL: recovery protocol missing $expected" >&2
    exit 1
  fi
done

coordinator_contract=(
  'initializeRequest'
  'resumeThreadRequest'
  'readThreadRequest'
  'startRecoveryTurnRequest'
  'alreadySubmitted'
  'completion'
)

for expected in "${coordinator_contract[@]}"; do
  if ! grep -Fq "$expected" "$coordinator_file"; then
    echo "FAIL: recovery coordinator missing $expected" >&2
    exit 1
  fi
done

transport_contract=(
  'CodexAppServerRecoveryTransport'
  'Process'
  'poll('
  'func exchange'
  'func receive'
)

for expected in "${transport_contract[@]}"; do
  if ! grep -Fq "$expected" "$transport_file"; then
    echo "FAIL: app-server transport missing $expected" >&2
    exit 1
  fi
done

echo "PASS: exact-thread protocol, coordinator, and independent transport contracts present"
