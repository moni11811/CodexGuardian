# Phase 2 Shadow Journal Review

Scope:

- `Package.swift`
- `Sources/GuardianCore/GuardianOperation.swift`
- `Sources/GuardianCore/GuardianJournal.swift`
- `Tests/GuardianCoreTests/GuardianJournalTests.swift`

## Findings

### P0 — Hard restart may bypass its quiet gate

Evidence: `GuardianOperationTransitionPolicy.allows` accepts `.prepared -> .targetLoaded` without inspecting `GuardianOperationKind` (`GuardianOperation.swift:95-131`). `transition` passes only phases (`GuardianJournal.swift:124-131`). A `.hardRestart` can therefore reach `continuationSent` without `gated`, `restartIssued`, Desktop readiness, or target-load evidence.

Required red test: a prepared `.hardRestart` transition to `.targetLoaded` must throw; a `.nativeRecovery` transition may take that route. Make policy kind-aware before repair.

### P0 — Journal cannot fence stale owners or prove replay-safe delivery

Evidence: schema stores only operation identity, phase, and timestamps (`GuardianJournal.swift:26-43`). No generation, owner lease, expected phase/version, attempt, outbox payload, delivery key, receipt, deadline, or restart budget exists. `transition` accepts any current operation ID and valid phase edge (`119-160`); a stale worker may still terminal-fail a newer operation state because terminal edges are broadly allowed (`GuardianOperation.swift:101-104`).

Required red tests: stale generation/lease transition rejected; one delivery key produces one outbox record/one accepted receipt after reconnect; expired lease cannot issue restart. Do not claim exact recovery from phase history alone.

### P1 — SQLite privacy and crash-durability settings are incomplete

Evidence: only the directory and main database receive permissions, after database creation/migration (`GuardianJournal.swift:8-49`). WAL and SHM sidecars can contain operation metadata but receive no permission assertion. No explicit `synchronous=FULL` (or documented alternative), secure file creation mode, checkpoint/recovery policy, or migration/open race test exists. Main-file chmod happens after a potentially default-permission creation window.

Required red tests: fresh DB, `-wal`, and `-shm` all owner-only; reopening after forced WAL-only write preserves atomic operation/event pair; existing insecure database rejects or repairs safely. Set and verify durability/permission policy before first sensitive write.

### P1 — Multi-process contention behavior is unproved and failure is opaque

Evidence: independent `DatabasePool` instances are possible; configuration only uses a two-second busy timeout (`GuardianJournal.swift:16-22`). SQLite serializes writers, but this API exposes raw GRDB busy/locked errors and no bounded retry/classification. Event index derives from `MAX` (`142-150`), transaction-safe for one writer but untested across pools/processes.

Required red tests: two separately opened journals concurrently create/advance operations; events stay contiguous, no duplicate receipt/event, and bounded lock exhaustion maps to a journal error that scheduler can defer. Include migration/open contention.

### P1 — Idempotency key scope permits duplicate recovery work

Evidence: `create` deduplicates only identical UUID plus full object equality (`GuardianJournal.swift:58-94`). A second UUID with the same origin token/thread/kind inserts another recovery operation. No uniqueness constraint or lookup covers the real recovery identity.

Required red test: same origin identity submitted twice with different operation IDs returns the original operation and creates no second event/restart intent. Decide explicit idempotency-key semantics; do not use timestamps as equality input.

### P2 — State model lacks event meaning and validation needed for audit/replay

Evidence: events contain phase/time only (`GuardianOperation.swift:68-85`). No actor, reason, observed Codex generation, evidence reference, error classification, or monotonic source sequence is journaled. `decodeOperation` validates enum strings but not empty thread/hash or timestamp ordering (`GuardianJournal.swift:175-196`).

Required red tests: invalid origin identity/time ordering rejected; replay reconstructs the same state and evidence identity; event records actor/reason/generation. This is needed for human audit and correct recovery after crash.

### P2 — Swift concurrency contract is asserted, not demonstrated

Evidence: `GuardianJournal` is `@unchecked Sendable` (`GuardianJournal.swift:4`) although public methods are synchronous and tests are single-threaded (`GuardianJournalTests.swift:5-61`). GRDB pool may be thread-safe, but the wrapper makes an unchecked claim without a stress test or isolation boundary.

Required red test: concurrent task-group access across one journal and separate reopened journals; document the chosen isolation (actor or GRDB-backed checked Sendable) and remove `@unchecked` if possible.

## Strengths

- Create plus initial event and phase update plus event are inside GRDB write transactions (`GuardianJournal.swift:62-94`, `124-160`): atomic within a committed SQLite transaction.
- Foreign key cascade and `(operation_id, event_index)` primary key protect basic event ownership/order (`35-43`).
- Same-phase transition is idempotent and unsafe simple skip is covered (`128-131`; test `27-60`).

## Remediation evidence

- Hard-restart transitions now require a generation-fenced lease and a kind-aware state edge. Red tests proved gate skipping and terminal-state rewriting before repair.
- Repeated origin tokens now return the original operation; conflicting thread/kind reuse fails closed.
- Durable outbox state is inserted in the same transaction as `continuationSent`. A sent-but-unacknowledged entry becomes `awaitingReconciliation` and is excluded from resend.
- Delivery receipt requires the exact operation/message ID, target thread, message item, and turn. Exact repeats are idempotent; conflicts fail closed.
- SQLite now explicitly requests WAL plus `synchronous=FULL`; DB, WAL, and SHM permission regression requires `0600` inside a `0700` directory.
- Focused journal/outbox proofs passed. Cross-pool concurrency proof is pending completion of the parallel IPC fail-first lane.

Still open before Phase 2 exit: durable restart budgets, richer event evidence, bounded busy-error mapping, encrypted payload keys, local authenticated socket, daemon lifecycle, install/rollback proof, and kill-at-every-edge replay.
# Continuation review lanes

## Persistence and crash-safety follow-up

### P0 — Crash after send can redeliver

Resolved: the only delivery API is now `beginOutboxDeliveryAttempt`. It atomically moves a pending row to `awaitingReconciliation` and returns that durable attempt before external I/O can begin. Reopen proof confirms it is no longer deliverable; callers must reconcile the operation ID in the exact target thread before any resend.

### P0 — Phase 2 crash/fault exit is unproved

Proofs cover orderly reopen and 12-pool contention (`GuardianJournalTests.swift:5-24`; `GuardianJournalConcurrencyTests.swift:5-69`), not kill-at-every-phase, interrupted transaction/migration, corrupt rows, disk/permission loss, bounded busy exhaustion, or install/uninstall/rollback (`CODEX_GUARDIAN_5X_PLAN.md:620-639`). Do not pass Phase 2 from in-process reopen tests.

### P1 — Corruption is not isolated

Bulk reads use throwing whole-array maps (`GuardianJournal.swift:339-362`), so one bad row hides healthy work. Restart-fence decode narrows signed integers without bounds checks (`GuardianJournal.swift:757-766`), allowing corrupt data to trap. Add quarantine/healthy-row continuity tests and validated numeric conversions.

Minimal red proof: seed a valid gated hard-restart operation/fence, mutate `process_id` to `Int64.max` and separately `process_start_identity` to `-1` through GRDB, then assert `issueRestart` throws `corruptStoredOperation` without terminating the test process; also reject negative `server_generation` and empty identity strings during decode.

### P1 — Lease lifecycle is incomplete

Same-owner reacquisition returns the old expiry (`GuardianJournal.swift:619-624`); no renew/release API or tests exist. Add CAS renewal, stale-renewer, explicit-release, crash-expiry takeover, and operation-resource binding proofs.

### P1 — Durable schema and hard-restart outbox are incomplete

Operations omit owner/generation/deadlines (`GuardianJournal.swift:31-40`); migrations omit task snapshots, client sessions, and incidents (`GuardianJournal.swift:30-130`). Hard restarts are rejected by the atomic enqueue API (`GuardianJournal.swift:366-404`). Add schema/replay tests before daemon authority.

### P1 — Production key lifecycle is absent

Cipher callers supply raw parent-key bytes (`GuardianPayloadCipher.swift:15-23`); tests use constants (`GuardianPayloadCipherTests.swift:5-19`, `41-46`). No Keychain store, rotation/revocation, or dead-letter key destruction exists. ACK cleanup alone is tested (`GuardianPayloadCipherTests.swift:22-75`).

Verified: atomic operation/outbox writes, WAL+FULL+0600, idempotent origin, fenced lease/restart identity, exact receipt, envelope binding, and persisted restart circuit have focused tests.

## Thin-client and local-auth follow-up

### P0 — Legacy Mac and MCP paths still bypass daemon authority

Only `guardian_status` uses `GuardianClient`. `AppModel` still owns its store, scanner, and restart flow; recovery MCP tools still execute legacy logic directly. Phase 2 must remain shadow-only until both become forwarding clients and the Phase 3 comparison/cutover proves that two supervisors cannot issue restart.

### P0 — Bearer token does not prove connected-server identity

The client validates the socket pathname, then transmits a reusable credential. Same-UID peer filtering plus token files rejects unregistered callers, but a same-UID decoy socket can still capture and replay a client token. Production destructive authority needs XPC/Mach audit-token and code-signature validation, or an equivalently bound challenge protocol. Current socket stays shadow-only.

### P1 — Blocking server lacks per-client containment

The daemon handles a blocking connection serially. Frame read and malformed-client failures need server-enforced deadlines, isolated connection failure, and a regression proving one client cannot starve or terminate the service.

### P1 — Packaging proof was incomplete

Added shared credential-file validation, malformed/symlink/permission/length regressions, and a real `guardian_status` smoke exchange against a one-shot Unix daemon. Still required: wrong-token/role, decoy socket/server identity, upgrade/rollback, and production launchd proof.
