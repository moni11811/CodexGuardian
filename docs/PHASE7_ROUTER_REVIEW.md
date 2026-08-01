# Phase 7 authenticated router review

Shared evidence log for signed observe routing. No network listener activation in this lane.

## RED: snapshot authorization boundary

- Theory: a standalone snapshot route can bypass signed command validation and leak task state. Snapshot production must be a consequence of a signed, capability-checked `.observe` command that first receives a durable acceptance receipt.
- Added `Tests/GuardianCoreTests/GuardianRemoteRequestRouterTests.swift`.
- Contract covered: authenticated observe returns one response containing the original request ID, explicit receipt, and authoritative snapshot; forged observe returns the gateway signature rejection and never invokes the snapshot provider; unsigned snapshot returns `unauthorized` and never invokes the provider.
- Focused command: `swift test --filter GuardianRemoteRequestRouterTests` with isolated Swift/Clang module caches.
- RED evidence: exit 1. Compiler reports `cannot find 'GuardianRemoteRequestRouter' in scope` at lines 14, 44, and 73. This is the intended missing production boundary; cascading contextual-member errors follow because no router result type exists yet.
- Production source changed: none.
