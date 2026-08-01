#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
codex_binary="${CODEX_BINARY:-/Applications/ChatGPT.app/Contents/Resources/codex}"
proof_binary="$(/usr/bin/mktemp /tmp/CodexGuardianGate0.XXXXXX)"

cleanup() {
  /bin/rm -f "$proof_binary"
}
trap cleanup EXIT

if [[ ! -x "$codex_binary" ]]; then
  echo "FAIL: installed Codex binary not executable: $codex_binary" >&2
  exit 1
fi

/usr/bin/swiftc \
  "$repo_root/Sources/GuardianCore/CodexAppServerRecoveryProtocol.swift" \
  "$repo_root/Sources/GuardianCore/CodexAppServerRecoveryCoordinator.swift" \
  "$repo_root/Sources/GuardianCore/CodexAppServerRecoveryLiveness.swift" \
  "$repo_root/Sources/GuardianCore/CodexAppServerStdioTransport.swift" \
  "$repo_root/script/Gate0ProtocolSelfTest.swift" \
  -o "$proof_binary"

"$proof_binary" \
  "$repo_root/Tests/GuardianCoreTests/Fixtures/FakeCodexAppServer.py" \
  "$codex_binary"
