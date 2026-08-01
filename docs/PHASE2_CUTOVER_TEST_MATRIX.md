# Phase 2 Cutover Fence Test Matrix

Bounded regression review. No implementation authority.

## Failure theory

During upgrade, legacy menu/MCP code and the daemon can overlap. Without one durable, monotonic authority fence, both can pass their own local checks and issue the same restart. Process-local flags, launch order, binary version, and request-file ownership are not authority.

The fence must be committed in SQLite before the daemon gains destructive capability. Every destructive entry point must read it inside the same serialized decision path that acquires the restart lease. Missing, unreadable, corrupt, incompatible, or stale fence evidence fails closed. Once daemon authority is committed, rollback must never silently restore legacy authority.

Phase 2 remains shadow-only. These tests should be written red now; the destructive cutover may turn green only with the Phase 3 atomic cutover.

## Required mixed-version failure matrix

Contract names below are test-facing pseudocode. Side-effect counters must wrap the actual process-controller boundary, not merely policy return values.

| ID | Interleaving / fault | Required result | Exact assertions |
| --- | --- | --- | --- |
| C1 | Fresh database; legacy menu and daemon both receive the same armed request before any cutover | Legacy remains sole authority; daemon observes only | `#expect(fence.mode == .legacy)`; `#expect(legacySideEffects == 1)`; `#expect(daemonSideEffects == 0)`; `#expect(journal.operations(originTokenHash: hash).count == 1)` |
| C2 | Cutover preconditions pass, then process dies before the fence transaction commits | Reopen remains legacy; no daemon restart | `#expect(reopenedFence.mode == .legacy)`; `#expect(reopenedFence.generation == 0)`; `#expect(daemonSideEffects == 0)`; `#expect(journal.events(operationID: id).contains(where: { $0.phase == .restartIssued }) == false)` |
| C3 | Fence commit succeeds, then daemon dies before clients reload | Reopen preserves daemon authority; old binary cannot act | `#expect(reopenedFence.mode == .daemon)`; `#expect(reopenedFence.generation == 1)`; `#expect(legacyDecision == .blocked(.authorityTransferred))`; `#expect(legacySideEffects == 0)` |
| C4 | Old menu, old MCP, and daemon race after committed cutover | Exactly one daemon-owned side effect; all legacy paths forward or fail closed | `#expect(daemonSideEffects == 1)`; `#expect(legacyMenuSideEffects == 0)`; `#expect(legacyMCPSideEffects == 0)`; `#expect(Set(journal.operations(originTokenHash: hash).map(\.id)).count == 1)` |
| C5 | Old binary cached a pre-cutover read, daemon commits generation 1, old binary later attempts restart | Stale read loses to transactional generation/lease check | `#expect(throws: GuardianAuthorityError.staleGeneration(expected: 0, actual: 1)) { try legacyExecutor.issueRestart(...) })`; `#expect(legacySideEffects == 0)`; `#expect(fence.generation == 1)` |
| C6 | Two daemon generations race across daemon relaunch | Only current generation and current restart lease may advance | `#expect(throws: GuardianJournalError.staleLease("desktop-restart")) { try oldDaemon.advance(...) })`; `#expect(newDaemonSideEffects == 1)`; `#expect(oldDaemonSideEffects == 0)`; `#expect(operation.phase == .restartIssued)` |
| C7 | A legacy request file exists at cutover and the equivalent journal operation already exists | Reconcile by origin token; never import a duplicate | `#expect(importedOperation.id == existingOperation.id)`; `#expect(journal.operations(originTokenHash: hash).count == 1)`; `#expect(legacyFileDisposition == .archivedReconciled)`; `#expect(totalSideEffects == 1)` |
| C8 | A legacy request has no origin token or verified continuation automation | Preserve/quarantine; cutover cannot execute it | `#expect(disposition == .quarantined(.continuationNotArmed))`; `#expect(totalSideEffects == 0)`; `#expect(quarantine.contains(request.id))`; `#expect(journal.operations().contains(where: { $0.originThreadID == request.threadID })) == false` |
| C9 | A legacy restart is already past its irreversible side-effect boundary when cutover is requested | Cutover rejected until reconciliation proves terminal state | `#expect(cutoverDecision == .blocked(.legacyOperationInFlight))`; `#expect(fence.mode == .legacy)`; `#expect(fence.generation == 0)`; `#expect(daemonSideEffects == 0)` |
| C10 | Authority row is missing, corrupt, unreadable, or schema-newer after any install has advertised daemon authority | Both paths fail closed; no inferred fallback | For each fault: `#expect(legacyDecision == .blocked(.authorityUnprovable))`; `#expect(daemonDecision == .blocked(.authorityUnprovable))`; `#expect(totalSideEffects == 0)` |
| C11 | Downgrade/rollback launches a legacy-only binary against a database with committed daemon authority | Rollback preserves data but cannot regain restart authority | `#expect(legacyDecision == .blocked(.unsupportedAuthorityEpoch))`; `#expect(fence.mode == .daemon)`; `#expect(fence.generation == 1)`; `#expect(totalSideEffects == 0)` |
| C12 | Cutover requested with incomplete/stale/conflicting task inventory | Fence is not committed | `#expect(cutoverDecision == .blocked(.inventoryNotAuthoritative))`; `#expect(fence.mode == .legacy)`; `#expect(fence.generation == 0)`; `#expect(totalSideEffects == 0)` |
| C13 | Cutover transaction commits fence but fails while recording audit event | Entire transaction rolls back | `#expect(reopenedFence.mode == .legacy)`; `#expect(reopenedFence.generation == 0)`; `#expect(journal.authorityEvents().isEmpty)`; `#expect(totalSideEffects == 0)` |
| C14 | Operator repeats cutover after committed generation 1 | Idempotent; no generation bump or second event | `#expect(second == first)`; `#expect(fence.generation == 1)`; `#expect(journal.authorityEvents().filter { $0.to == .daemon }.count == 1)`; `#expect(totalSideEffects == 0)` |
| C15 | Manual Force Restart is invoked from an old menu after cutover | Human confirmation does not bypass ownership or exact-continuation proof | `#expect(decision == .blocked(.authorityTransferred))`; `#expect(legacySideEffects == 0)`; `#expect(request.recoveryPhase != .restartIssued)` |

## Minimal red-first test set

Add one focused file: `Tests/GuardianCoreTests/GuardianAuthorityCutoverTests.swift`. Keep production effects behind injected recorders. Write these tests before the fence implementation:

1. `cutoverCommitIsAtomicAcrossCrash` — covers C2, C3, C13. Inject faults immediately before and after the SQLite commit. Assert reopened mode/generation, exactly one authority event after a committed cutover, and zero side effects before restart execution.
2. `mixedLegacyAndDaemonCallersProduceOneDaemonSideEffect` — covers C4, C5, C6. Start all callers behind one barrier. Assert daemon count `1`, every legacy/stale count `0`, one operation ID, and one `restartIssued` event.
3. `pendingLegacyRequestsReconcileWithoutDuplicateOrUnsafeImport` — covers C7, C8, C9. Assert exact origin-token reuse, unarmed quarantine, and cutover rejection for an irreversible in-flight legacy operation.
4. `unprovableOrUnsupportedFenceBlocksEveryDestructivePath` — table-drive missing/corrupt/unreadable/newer-schema and downgrade cases C10/C11. For every case assert both executor decisions are blocked and total side effects remain `0`.
5. `cutoverRequiresAuthoritativeInventoryAndIsIdempotent` — covers C12/C14. Assert incomplete inventory leaves generation `0`; two valid requests produce one generation-1 fence and one audit event.
6. Extend `GuardianManualRestartPolicyTests.swift` with `manualForceCannotOverrideCommittedDaemonAuthority` — covers C15. Exact assertions: `#expect(policy.decision(..., authority: .daemon) == .blocked(.authorityTransferred))` and `#expect(processController.restartCount == 0)`.

## Exit evidence

- Run the focused file alone first. Preserve the initial failing output as red evidence.
- Run it against a real SQLite file, reopen between fault boundaries, and use at least two independent journal connections.
- Run existing lease, restart-fence, request-store, manual-force, and crash-worker suites unchanged.
- Phase 2 exit still reports `shadow_only`. Phase 3 cutover is allowed only when C1–C15 pass and every Mac/MCP destructive path routes through the same fence-plus-lease transaction.
