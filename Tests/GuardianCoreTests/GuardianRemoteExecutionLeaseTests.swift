import CryptoKit
import Foundation
import GuardianCore
import Testing

private let executionLeaseNow = Date(timeIntervalSince1970: 9_000)
private let executionLeaseGeneration: Int64 = 31

@Test func racingRemoteExecutorsClaimExactlyOneEncryptedCommand() async throws {
    let fixture = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let first = fixture.journal
    let second = try GuardianJournal(databaseURL: fixture.databaseURL)
    let owners = [UUID(), UUID()]

    let claims = try await withThrowingTaskGroup(
        of: GuardianRemoteCommandLease?.self
    ) { group in
        for (journal, owner) in zip([first, second], owners) {
            group.addTask {
                await Task.yield()
                return try journal.claimNextRemoteCommand(
                    ownerID: owner,
                    currentDaemonGeneration: executionLeaseGeneration,
                    now: executionLeaseNow.addingTimeInterval(3),
                    leaseDuration: 10
                )
            }
        }
        var values: [GuardianRemoteCommandLease?] = []
        for try await value in group { values.append(value) }
        return values
    }

    let lease = try #require(claims.compactMap { $0 }.only)
    #expect(claims.compactMap { $0 }.count == 1)
    #expect(lease.binding.commandID == fixture.command.commandID)
    #expect(lease.leaseGeneration == 1)
    #expect(lease.attemptCount == 1)
    #expect(try fixture.cipher.open(
        lease.sealedPayload,
        binding: lease.binding
    ) == fixture.payload)
}

@Test func expiredRemoteClaimIsReclaimedAndOldOwnerIsFenced() throws {
    let fixture = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let firstOwner = UUID()
    let secondOwner = UUID()
    let first = try #require(try fixture.journal.claimNextRemoteCommand(
        ownerID: firstOwner,
        currentDaemonGeneration: executionLeaseGeneration,
        now: executionLeaseNow.addingTimeInterval(3),
        leaseDuration: 1
    ))

    let reopened = try GuardianJournal(databaseURL: fixture.databaseURL)
    let reclaimed = try #require(try reopened.claimNextRemoteCommand(
        ownerID: secondOwner,
        currentDaemonGeneration: executionLeaseGeneration,
        now: executionLeaseNow.addingTimeInterval(5),
        leaseDuration: 2
    ))
    #expect(reclaimed.ownerID == secondOwner)
    #expect(reclaimed.leaseGeneration == first.leaseGeneration + 1)
    #expect(reclaimed.attemptCount == first.attemptCount + 1)

    #expect(throws: GuardianJournalError.staleLease(
        "remote-command:\(fixture.command.commandID.uuidString)"
    )) {
        try fixture.journal.renewRemoteCommandLease(
            first,
            now: executionLeaseNow.addingTimeInterval(5),
            leaseDuration: 2
        )
    }
    #expect(throws: GuardianJournalError.staleLease(
        "remote-command:\(fixture.command.commandID.uuidString)"
    )) {
        try fixture.journal.completeRemoteCommand(
            first,
            completion: .applied,
            at: executionLeaseNow.addingTimeInterval(5)
        )
    }
    #expect(try fixture.journal.remoteCommandOutcome(
        commandID: fixture.command.commandID
    )?.state == .pending)
    let renewed = try reopened.renewRemoteCommandLease(
        reclaimed,
        now: executionLeaseNow.addingTimeInterval(5.5),
        leaseDuration: 2
    )
    #expect(renewed.ownerID == secondOwner)
    #expect(renewed.leaseGeneration == reclaimed.leaseGeneration + 1)
    #expect(renewed.leaseExpiresAt > reclaimed.leaseExpiresAt)
    #expect(try reopened.completeRemoteCommand(
        renewed,
        completion: .applied,
        at: executionLeaseNow.addingTimeInterval(6)
    ).state == .applied(at: executionLeaseNow.addingTimeInterval(6)))
}

@Test func staleGenerationQueuedCommandTerminalizesInsteadOfPendingForever() throws {
    let fixture = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let terminalAt = executionLeaseNow.addingTimeInterval(3)

    #expect(try fixture.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: executionLeaseGeneration + 1,
        now: terminalAt,
        leaseDuration: 10
    ) == nil)
    let staleOutcome = try #require(try fixture.journal.remoteCommandOutcome(
        commandID: fixture.command.commandID
    ))
    #expect(staleOutcome.state == .failed(code: .generationChanged, at: terminalAt))
    #expect(try fixture.journal.remoteAuditEvents(limit: 20).filter {
        $0.kind == .commandFailed && $0.commandID == fixture.command.commandID
    }.count == 1)
}

@Test func expiredOrRevokedQueuedCommandTerminalizesBeforeAdapterClaim() throws {
    let expired = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: expired.directory) }
    let expiredAt = executionLeaseNow.addingTimeInterval(31)
    #expect(try expired.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: executionLeaseGeneration,
        now: expiredAt,
        leaseDuration: 10
    ) == nil)
    let expiredOutcome = try #require(try expired.journal.remoteCommandOutcome(
        commandID: expired.command.commandID
    ))
    #expect(expiredOutcome.state == .failed(code: .deadlineExceeded, at: expiredAt))

    let revoked = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: revoked.directory) }
    _ = try revoked.journal.revokeRemoteDevice(
        id: revoked.command.deviceID,
        expectedRevocationEpoch: 0,
        at: executionLeaseNow.addingTimeInterval(3)
    )
    let revokedAt = executionLeaseNow.addingTimeInterval(4)
    #expect(try revoked.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: executionLeaseGeneration,
        now: revokedAt,
        leaseDuration: 10
    ) == nil)
    let revokedOutcome = try #require(try revoked.journal.remoteCommandOutcome(
        commandID: revoked.command.commandID
    ))
    #expect(revokedOutcome.state == .failed(code: .policyDenied, at: revokedAt))
}

@Test func preparedEffectExpiresIntoReconciliationNeverOrdinaryRequeue() throws {
    let fixture = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let firstOwner = UUID()
    let lease = try #require(try fixture.journal.claimNextRemoteCommand(
        ownerID: firstOwner,
        currentDaemonGeneration: executionLeaseGeneration,
        now: executionLeaseNow.addingTimeInterval(3),
        leaseDuration: 2
    ))
    let adapter = GuardianAdapterIdentity(id: "codex-desktop", version: "1")
    let fences = GuardianRemoteEffectFences(
        authorityEpoch: 4,
        policyEpoch: 7,
        targetRevision: "thread-revision-9"
    )
    let preparation = try fixture.journal.prepareRemoteCommandEffect(
        lease,
        adapter: adapter,
        fences: fences,
        evidenceID: "evidence-safe-1",
        at: executionLeaseNow.addingTimeInterval(4)
    )
    #expect(preparation.idempotencyKey == fixture.command.commandID)
    #expect(preparation.adapter == adapter)
    #expect(preparation.fences == fences)
    #expect(preparation.lease.version == lease.version + 1)

    let expiredAt = executionLeaseNow.addingTimeInterval(6)
    #expect(try fixture.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: executionLeaseGeneration,
        now: expiredAt,
        leaseDuration: 5
    ) == nil)
    let reconciliation = try #require(
        try fixture.journal.claimRemoteCommandForReconciliation(
            ownerID: UUID(),
            currentDaemonGeneration: executionLeaseGeneration + 1,
            now: expiredAt,
            leaseDuration: 5
        )
    )
    #expect(reconciliation.idempotencyKey == preparation.idempotencyKey)
    #expect(reconciliation.adapter == adapter)
    #expect(reconciliation.lease.attemptCount == preparation.lease.attemptCount)
    #expect(reconciliation.lease.leaseGeneration == preparation.lease.leaseGeneration + 1)
}

@Test func invocationBoundaryFencesTerminalIndeterminateOutcome() throws {
    let fixture = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let lease = try #require(try fixture.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: executionLeaseGeneration,
        now: executionLeaseNow.addingTimeInterval(3),
        leaseDuration: 10
    ))
    let preparation = try fixture.journal.prepareRemoteCommandEffect(
        lease,
        adapter: GuardianAdapterIdentity(id: "codex-desktop", version: "1"),
        fences: GuardianRemoteEffectFences(
            authorityEpoch: 4,
            policyEpoch: 7,
            targetRevision: "thread-revision-9"
        ),
        evidenceID: "effect-safe-2",
        at: executionLeaseNow.addingTimeInterval(4)
    )
    let invoked = try fixture.journal.markRemoteCommandInvoked(
        preparation,
        at: executionLeaseNow.addingTimeInterval(5)
    )
    #expect(invoked.lease.version == preparation.lease.version + 1)
    #expect(throws: GuardianJournalError.staleLease(lease.resource)) {
        try fixture.journal.completeRemoteCommand(
            preparation.lease,
            completion: .applied,
            at: executionLeaseNow.addingTimeInterval(6)
        )
    }
    let terminalAt = executionLeaseNow.addingTimeInterval(6)
    #expect(try fixture.journal.completeRemoteCommand(
        invoked.lease,
        completion: .indeterminate(.ambiguousEffect),
        at: terminalAt
    ).state == .indeterminate(code: .ambiguousEffect, at: terminalAt))
}

@Test func remoteExecutorReconcilesThenAppliesOnceWithStableIdempotencyKey() async throws {
    let fixture = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let adapter = ExecutionAdapterProbe(
        reconciliation: .notApplied(evidenceID: "not-applied-1"),
        application: .applied(evidenceID: "applied-1")
    )
    let executor = GuardianRemoteCommandExecutor(
        journal: fixture.journal,
        ownerID: UUID(),
        currentDaemonGeneration: executionLeaseGeneration,
        payloadOpener: { envelope, binding in
            try fixture.cipher.open(envelope, binding: binding)
        },
        authorizationProvider: { _ in
            GuardianRemoteEffectAuthorization(
                fences: GuardianRemoteEffectFences(
                    authorityEpoch: 4,
                    policyEpoch: 7,
                    targetRevision: "thread-revision-9"
                ),
                evidenceID: "executor-safe-1"
            )
        },
        adapters: [adapter]
    )

    let outcome = try #require(try await executor.runNext(
        now: executionLeaseNow.addingTimeInterval(3)
    ))
    guard case .applied = outcome.state else {
        Issue.record("Executor did not persist applied outcome")
        return
    }
    #expect(await adapter.reconcileCount == 1)
    #expect(await adapter.applyCount == 1)
    #expect(await adapter.lastIdempotencyKey == fixture.command.commandID)
    #expect(await adapter.lastPayload == fixture.payload)
}

@Test func executorRejectsUngroundedAppliedProofAsIndeterminate() async throws {
    let fixture = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let adapter = ExecutionAdapterProbe(
        reconciliation: .applied(evidenceID: ""),
        application: .applied(evidenceID: "must-not-run")
    )
    let executor = GuardianRemoteCommandExecutor(
        journal: fixture.journal,
        ownerID: UUID(),
        currentDaemonGeneration: executionLeaseGeneration,
        payloadOpener: { envelope, binding in
            try fixture.cipher.open(envelope, binding: binding)
        },
        authorizationProvider: { _ in
            GuardianRemoteEffectAuthorization(
                fences: GuardianRemoteEffectFences(
                    authorityEpoch: 4,
                    policyEpoch: 7,
                    targetRevision: "thread-revision-9"
                ),
                evidenceID: "executor-safe-2"
            )
        },
        adapters: [adapter]
    )

    let outcome = try #require(try await executor.runNext(
        now: executionLeaseNow.addingTimeInterval(3)
    ))
    #expect(outcome.state == .indeterminate(
        code: .ambiguousEffect,
        at: executionLeaseNow.addingTimeInterval(3)
    ))
    #expect(await adapter.applyCount == 0)
}

@Test func ambiguousApplyIsReconciledWithoutSecondSemanticEffect() async throws {
    let fixture = try executionLeaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let adapter = ExecutionAdapterProbe(
        reconciliations: [
            .notApplied(evidenceID: "before-apply"),
            .applied(evidenceID: "after-ambiguous-apply"),
        ],
        application: .applied(evidenceID: "unreturned-apply"),
        throwsOnFirstApply: true
    )
    let executor = GuardianRemoteCommandExecutor(
        journal: fixture.journal,
        ownerID: UUID(),
        currentDaemonGeneration: executionLeaseGeneration,
        payloadOpener: { envelope, binding in
            try fixture.cipher.open(envelope, binding: binding)
        },
        authorizationProvider: { _ in
            GuardianRemoteEffectAuthorization(
                fences: GuardianRemoteEffectFences(
                    authorityEpoch: 4,
                    policyEpoch: 7,
                    targetRevision: "thread-revision-9"
                ),
                evidenceID: "executor-safe-3"
            )
        },
        adapters: [adapter]
    )

    let ambiguous = try #require(try await executor.runNext(
        now: executionLeaseNow.addingTimeInterval(3)
    ))
    #expect(ambiguous.state == .pending)
    let reconciled = try #require(try await executor.runNext(
        now: executionLeaseNow.addingTimeInterval(14)
    ))
    guard case .applied = reconciled.state else {
        Issue.record("Reconciliation did not prove applied effect")
        return
    }
    #expect(await adapter.reconcileCount == 2)
    #expect(await adapter.applyCount == 1)
    #expect(await adapter.lastIdempotencyKey == fixture.command.commandID)
}

private struct ExecutionLeaseFixture {
    let directory: URL
    let databaseURL: URL
    let journal: GuardianJournal
    let cipher: GuardianRemotePayloadCipher
    let command: GuardianRemoteCommand
    let payload: Data
}

private func executionLeaseFixture() throws -> ExecutionLeaseFixture {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-execution-lease-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appending(path: "guardian.sqlite")
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let deviceKey = Curve25519.Signing.PrivateKey()
    let challenge = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: Data(repeating: 0xA1, count: 32),
        expiresAt: executionLeaseNow.addingTimeInterval(60),
        consumedAt: nil
    )
    let device = GuardianRemoteDevice(
        id: UUID(),
        publicKey: deviceKey.publicKey.rawRepresentation,
        capabilities: [.observe, .prompt],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: executionLeaseNow.addingTimeInterval(1),
        lastSeenAt: nil
    )
    try journal.issuePairingChallenge(challenge, issuedAt: executionLeaseNow)
    try journal.pairRemoteDevice(
        device,
        challenge: challenge,
        at: executionLeaseNow.addingTimeInterval(1)
    )
    let payload = Data("execute once".utf8)
    let command = GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(),
        deviceID: device.id,
        expectedGeneration: executionLeaseGeneration,
        sequence: 1,
        nonce: UUID(),
        issuedAt: executionLeaseNow.addingTimeInterval(1),
        deadline: executionLeaseNow.addingTimeInterval(30),
        revocationEpoch: 0,
        targetThreadID: "execution-lease-thread",
        action: .prompt,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
    let cipher = try GuardianRemotePayloadCipher(
        parentKeyData: Data(repeating: 0xA2, count: 32)
    )
    guard case .accepted = try journal.reconcileRemoteCommand(
        command,
        sealedPayload: cipher.seal(payload, for: command),
        currentGeneration: executionLeaseGeneration,
        now: executionLeaseNow.addingTimeInterval(2)
    ) else {
        throw ExecutionLeaseFixtureError.commandNotAccepted
    }
    return ExecutionLeaseFixture(
        directory: directory,
        databaseURL: databaseURL,
        journal: journal,
        cipher: cipher,
        command: command,
        payload: payload
    )
}

private enum ExecutionLeaseFixtureError: Error {
    case commandNotAccepted
}

private actor ExecutionAdapterProbe: GuardianRemoteExecutionAdapter {
    nonisolated let identity = GuardianAdapterIdentity(id: "codex-desktop", version: "1")
    private let reconciliations: [GuardianRemoteReconciliationProof]
    private let application: GuardianRemoteApplyResult
    private let throwsOnFirstApply: Bool
    private(set) var reconcileCount = 0
    private(set) var applyCount = 0
    private(set) var lastIdempotencyKey: UUID?
    private(set) var lastPayload: Data?

    init(
        reconciliation: GuardianRemoteReconciliationProof,
        application: GuardianRemoteApplyResult
    ) {
        reconciliations = [reconciliation]
        self.application = application
        throwsOnFirstApply = false
    }

    init(
        reconciliations: [GuardianRemoteReconciliationProof],
        application: GuardianRemoteApplyResult,
        throwsOnFirstApply: Bool
    ) {
        self.reconciliations = reconciliations
        self.application = application
        self.throwsOnFirstApply = throwsOnFirstApply
    }

    nonisolated func supports(_ action: GuardianRemoteAction) -> Bool {
        action == .prompt
    }

    func reconcile(
        _ context: GuardianRemoteEffectContext
    ) async throws -> GuardianRemoteReconciliationProof {
        reconcileCount += 1
        lastIdempotencyKey = context.idempotencyKey
        return reconciliations[min(reconcileCount - 1, reconciliations.count - 1)]
    }

    func apply(
        _ payload: Data,
        context: GuardianRemoteEffectContext
    ) async throws -> GuardianRemoteApplyResult {
        applyCount += 1
        lastIdempotencyKey = context.idempotencyKey
        lastPayload = payload
        if throwsOnFirstApply && applyCount == 1 {
            throw ExecutionAdapterProbeError.ambiguousApply
        }
        return application
    }
}

private enum ExecutionAdapterProbeError: Error {
    case ambiguousApply
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
