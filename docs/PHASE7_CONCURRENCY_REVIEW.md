# Phase 7 remote journal concurrency review

## Bug theory

Two `GuardianJournal` instances share one SQLite file. If each validates the same
device sequence and replay nonce before the other commits, exactly-once handling
could degrade into a storage error, two side effects, or state that disagrees
with the audit log. A command racing device revocation could likewise be
accepted after revocation or leave a mixed final state.

## Regression coverage

`GuardianRemoteJournalConcurrencyTests.swift` opens independent journal handles
against one database and checks:

- Same command race: exactly one `.accepted`, exactly one `.duplicate`, equal
  receipts, sequence advances once, and one `commandAccepted` audit event.
- Acceptance/revocation race: either accept then revoke, or revoke then reject.
  Final device state and audit counts must match that single legal ordering.

## Evidence

Command:

```text
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codexguardian-swift-cache \
CLANG_MODULE_CACHE_PATH=/tmp/codexguardian-swift-cache \
swift test --filter GuardianRemoteJournalConcurrencyTests
```

- RED prerequisite run: test target did not compile because optional result
  types inside `#require` were ambiguous and one throwing lookup lacked an
  inner `try`. This was a test-only defect; no runtime concurrency claim was
  established by that run.
- Corrective change: explicit result types and explicit throwing expression.
- GREEN run: 2 Swift Testing tests passed in 0.025 seconds.
- Production source changes: none.

## Evidence boundary

The focused race did not reproduce a production defect. It establishes a
regression guard for the current transaction serialization. It does not prove
behavior under process kill, disk I/O failure, corrupt rows, or a deliberately
held SQLite lock; those require the crash/fault-injection suites.
