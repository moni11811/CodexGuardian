import Darwin
import Foundation
import GuardianCore

private enum CrashScenario: String, CaseIterable {
    case nativePrepared = "native-prepared"
    case nativeTargetLoaded = "native-target-loaded"
    case nativeContinuationSent = "native-continuation-sent"
    case nativeDeliveryAttempt = "native-delivery-attempt"
    case nativeDeliveryReceipt = "native-delivery-receipt"
    case nativeMonitoring = "native-monitoring"
    case nativeWaitingUser = "native-waiting-user"
    case nativeAcknowledged = "native-acknowledged"
    case nativeFailed = "native-failed"
    case nativeTimedOut = "native-timed-out"
    case nativeDeadLetter = "native-dead-letter"
    case hardPrepared = "hard-prepared"
    case hardGated = "hard-gated"
    case hardRestartIssued = "hard-restart-issued"
    case hardDesktopStarted = "hard-desktop-started"
    case hardControlReady = "hard-control-ready"
    case hardTargetLoaded = "hard-target-loaded"
    case rollbackCreate = "rollback-create"
    case rollbackTransition = "rollback-transition"
    case rollbackOutboxEnqueue = "rollback-outbox-enqueue"
    case rollbackReceipt = "rollback-receipt"
    case rollbackAcknowledgement = "rollback-ack"
    case authorityPrepared = "authority-prepared"
    case authorityActivated = "authority-activated"
    case rollbackAuthorityPrepare = "rollback-authority-prepare"
    case rollbackAuthorityActivate = "rollback-authority-activate"
    case rollbackRemotePairing = "rollback-remote-pairing"
    case rollbackRemoteAcceptance = "rollback-remote-acceptance"
    case rollbackRemoteQueue = "rollback-remote-queue"
    case rollbackRemoteRevocation = "rollback-remote-revocation"
    case rollbackRemoteCompletion = "rollback-remote-completion"
    case rollbackRemoteClaim = "rollback-remote-claim"
    case rollbackRemotePrepare = "rollback-remote-prepare"
    case rollbackRemoteInvoke = "rollback-remote-invoke"
    case rollbackRemoteAck = "rollback-remote-ack"
    case remoteCommandAccepted = "remote-command-accepted"
    case rollbackDaemonEvent = "rollback-daemon-event"

    var kind: GuardianOperationKind {
        rawValue.hasPrefix("hard-") ? .hardRestart : .nativeRecovery
    }

    var expectedPhase: GuardianOperationPhase {
        switch self {
        case .nativePrepared, .hardPrepared, .rollbackCreate, .rollbackTransition,
             .authorityPrepared, .authorityActivated, .rollbackAuthorityPrepare,
             .rollbackAuthorityActivate, .rollbackRemotePairing,
             .rollbackRemoteAcceptance, .rollbackRemoteRevocation,
             .rollbackRemoteQueue, .rollbackRemoteCompletion, .rollbackRemoteClaim,
             .rollbackRemotePrepare, .rollbackRemoteInvoke, .rollbackRemoteAck,
             .remoteCommandAccepted,
             .rollbackDaemonEvent:
            .prepared
        case .nativeTargetLoaded, .hardTargetLoaded: .targetLoaded
        case .nativeContinuationSent, .nativeDeliveryAttempt, .rollbackReceipt: .continuationSent
        case .nativeDeliveryReceipt, .rollbackAcknowledgement: .deliveryReceipt
        case .nativeMonitoring: .monitoring
        case .nativeWaitingUser: .waitingUser
        case .nativeAcknowledged: .acknowledged
        case .nativeFailed: .failed
        case .nativeTimedOut: .timedOut
        case .nativeDeadLetter: .deadLetter
        case .hardGated: .gated
        case .hardRestartIssued: .restartIssued
        case .hardDesktopStarted: .desktopStarted
        case .hardControlReady: .controlReady
        case .rollbackOutboxEnqueue: .targetLoaded
        }
    }

    var expectedEvents: [GuardianOperationPhase] {
        switch self {
        case .nativePrepared, .hardPrepared, .rollbackCreate, .rollbackTransition:
            [.prepared]
        case .authorityPrepared, .authorityActivated, .rollbackAuthorityPrepare,
             .rollbackAuthorityActivate, .rollbackRemotePairing,
             .rollbackRemoteAcceptance, .rollbackRemoteRevocation,
             .rollbackRemoteQueue, .rollbackRemoteCompletion, .rollbackRemoteClaim,
             .rollbackRemotePrepare, .rollbackRemoteInvoke, .rollbackRemoteAck,
             .remoteCommandAccepted,
             .rollbackDaemonEvent:
            []
        case .nativeTargetLoaded:
            [.prepared, .targetLoaded]
        case .nativeContinuationSent, .nativeDeliveryAttempt, .rollbackReceipt:
            [.prepared, .targetLoaded, .continuationSent]
        case .nativeDeliveryReceipt, .rollbackAcknowledgement:
            [.prepared, .targetLoaded, .continuationSent, .deliveryReceipt]
        case .nativeMonitoring:
            [.prepared, .targetLoaded, .continuationSent, .deliveryReceipt, .monitoring]
        case .nativeWaitingUser:
            [.prepared, .targetLoaded, .continuationSent, .deliveryReceipt, .monitoring, .waitingUser]
        case .nativeAcknowledged:
            [.prepared, .targetLoaded, .continuationSent, .deliveryReceipt, .acknowledged]
        case .nativeFailed:
            [.prepared, .failed]
        case .nativeTimedOut:
            [.prepared, .timedOut]
        case .nativeDeadLetter:
            [.prepared, .failed, .deadLetter]
        case .hardGated:
            [.prepared, .gated]
        case .hardRestartIssued:
            [.prepared, .gated, .restartIssued]
        case .hardDesktopStarted:
            [.prepared, .gated, .restartIssued, .desktopStarted]
        case .hardControlReady:
            [.prepared, .gated, .restartIssued, .desktopStarted, .controlReady]
        case .hardTargetLoaded:
            [.prepared, .gated, .restartIssued, .desktopStarted, .controlReady, .targetLoaded]
        case .rollbackOutboxEnqueue:
            [.prepared, .targetLoaded]
        }
    }

    var isRollbackProbe: Bool {
        switch self {
        case .rollbackCreate, .rollbackTransition, .rollbackOutboxEnqueue,
             .rollbackReceipt, .rollbackAcknowledgement:
            true
        default:
            false
        }
    }

    var isAuthorityScenario: Bool {
        switch self {
        case .authorityPrepared, .authorityActivated, .rollbackAuthorityPrepare,
             .rollbackAuthorityActivate:
            true
        default:
            false
        }
    }

    var isRemoteScenario: Bool {
        switch self {
        case .rollbackRemotePairing, .rollbackRemoteAcceptance, .rollbackRemoteQueue,
             .rollbackRemoteRevocation, .rollbackRemoteCompletion,
             .rollbackRemoteClaim, .rollbackRemotePrepare, .rollbackRemoteInvoke,
             .rollbackRemoteAck, .remoteCommandAccepted:
            true
        default:
            false
        }
    }

    var isDaemonEventScenario: Bool {
        self == .rollbackDaemonEvent
    }

    var faultPoint: GuardianJournalFaultPoint? {
        switch self {
        case .rollbackCreate:
            .operationInsertedBeforeInitialEvent
        case .rollbackTransition:
            .operationPhaseUpdatedBeforeEvent(.targetLoaded)
        case .rollbackOutboxEnqueue:
            .outboxInsertedBeforePhaseTransition
        case .rollbackReceipt:
            .receiptStoredBeforePhaseTransition
        case .rollbackAcknowledgement:
            .acknowledgementStoredBeforePhaseTransition
        case .rollbackAuthorityPrepare:
            .authorityPreparedBeforeEvent
        case .rollbackAuthorityActivate:
            .authorityActivatedBeforeEvent
        case .rollbackRemotePairing:
            .remotePairingConsumedBeforeDevice
        case .rollbackRemoteAcceptance:
            .remoteCommandInsertedBeforeReceipt
        case .rollbackRemoteQueue:
            .remoteExecutionQueuedBeforeDeviceAdvance
        case .rollbackRemoteRevocation:
            .remoteRevocationUpdatedBeforeAudit
        case .rollbackRemoteCompletion:
            .remoteCommandOutcomeUpdatedBeforeAudit
        case .rollbackRemoteClaim:
            .remoteExecutionClaimedBeforeReturn
        case .rollbackRemotePrepare:
            .remoteEffectPreparedBeforeReturn
        case .rollbackRemoteInvoke:
            .remoteEffectInvokedBeforeReturn
        case .rollbackRemoteAck:
            .remoteOutcomeAckInsertedBeforePayloadDestroy
        case .rollbackDaemonEvent:
            .daemonEventInsertedBeforeSequenceAdvance
        default:
            nil
        }
    }
}

private func writeDaemonEventAndStop(
    databaseURL: URL,
    scenario: CrashScenario,
    markerURL: URL
) throws -> Never {
    guard let faultPoint = scenario.faultPoint else {
        throw WorkerError.assertion("missing daemon event rollback fault point")
    }
    let setup = try GuardianJournal(databaseURL: databaseURL)
    let state = try setup.beginDaemonGeneration(at: baseDate)
    let faulting = try GuardianJournal(
        databaseURL: databaseURL,
        faultInjector: rollbackFaultInjector(target: faultPoint, markerURL: markerURL)
    )
    _ = try faulting.appendDaemonEvent(
        kind: .taskChanged,
        operationID: nil,
        expectedGeneration: state.generation,
        at: baseDate.addingTimeInterval(1)
    )
    throw WorkerError.assertion("daemon event fault injector did not stop writer")
}

private enum WorkerError: Error, CustomStringConvertible {
    case usage
    case invalidScenario(String)
    case invalidOperationID(String)
    case assertion(String)

    var description: String {
        switch self {
        case .usage:
            "usage: guardian-journal-crash-worker <write|verify> <database> <scenario> <operation-id> [commit-marker]"
        case let .invalidScenario(value):
            "invalid scenario: \(value)"
        case let .invalidOperationID(value):
            "invalid operation id: \(value)"
        case let .assertion(message):
            "verification failed: \(message)"
        }
    }
}

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw WorkerError.assertion(message) }
}

private func operation(id: UUID, kind: GuardianOperationKind) -> GuardianOperation {
    GuardianOperation(
        id: id,
        kind: kind,
        originThreadID: "crash-harness-thread",
        originTokenHash: "crash-harness-\(id.uuidString)",
        phase: .prepared,
        createdAt: baseDate,
        updatedAt: baseDate
    )
}

private func outboxEntry(id: UUID) -> GuardianOutboxEntry {
    let date = baseDate.addingTimeInterval(2)
    return GuardianOutboxEntry(
        operationID: id,
        messageID: id,
        targetThreadID: "crash-harness-thread",
        sealedPayload: Data([0x43, 0x47]),
        state: .pending,
        attemptCount: 0,
        createdAt: date,
        updatedAt: date,
        receipt: nil
    )
}

private func receipt(id: UUID) -> GuardianDeliveryReceipt {
    GuardianDeliveryReceipt(
        operationID: id,
        messageID: id,
        targetThreadID: "crash-harness-thread",
        messageItemID: "crash-message-item",
        turnID: "crash-turn",
        acceptedAt: baseDate.addingTimeInterval(4)
    )
}

private func remoteChallenge() -> GuardianPairingChallenge {
    GuardianPairingChallenge(
        nonce: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
        guardianIdentityHash: Data(repeating: 0x47, count: 32),
        expiresAt: baseDate.addingTimeInterval(60),
        consumedAt: nil
    )
}

private func remoteDevice(id: UUID) -> GuardianRemoteDevice {
    GuardianRemoteDevice(
        id: id,
        publicKey: Data(repeating: 0x44, count: 32),
        capabilities: [.observe, .prompt, .policyRecovery],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: baseDate.addingTimeInterval(1),
        lastSeenAt: nil
    )
}

private func remoteCommand(deviceID: UUID) -> GuardianRemoteCommand {
    GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!,
        deviceID: deviceID,
        expectedGeneration: 7,
        sequence: 1,
        nonce: UUID(uuidString: "70000000-0000-0000-0000-000000000003")!,
        issuedAt: baseDate.addingTimeInterval(1),
        deadline: baseDate.addingTimeInterval(30),
        revocationEpoch: 0,
        targetThreadID: "crash-harness-thread",
        action: .prompt,
        force: false,
        payloadDigest: Data(repeating: 0x50, count: 32)
    )
}

private func remoteSealedPayload() -> GuardianRemoteSealedPayload {
    GuardianRemoteSealedPayload(
        envelopeVersion: 1,
        algorithm: .aesGCM256,
        sealedPayload: Data([0x01]),
        wrappedDEK: Data([0x02]),
        aadDigest: Data(repeating: 0x03, count: 32)
    )
}

private func publishCommitMarkerAndStop(at markerURL: URL) throws -> Never {
    try Data("committed\n".utf8).write(to: markerURL, options: .atomic)
    _ = raise(SIGSTOP)
    while true { pause() }
}

private func rollbackFaultInjector(
    target: GuardianJournalFaultPoint,
    markerURL: URL
) -> GuardianJournalFaultInjector {
    { point in
        guard point == target else { return }
        try? Data("inside-transaction\n".utf8).write(to: markerURL, options: .atomic)
        _ = raise(SIGSTOP)
        while true { pause() }
    }
}

private func stopIfNeeded(
    _ scenario: CrashScenario,
    is checkpoint: CrashScenario,
    markerURL: URL
) throws {
    if scenario == checkpoint {
        try publishCommitMarkerAndStop(at: markerURL)
    }
}

private func writeNativeAndStop(
    journal: GuardianJournal,
    scenario: CrashScenario,
    operationID: UUID,
    markerURL: URL
) throws -> Never {
    if scenario == .nativeFailed || scenario == .nativeTimedOut || scenario == .nativeDeadLetter {
        let first: GuardianOperationPhase = scenario == .nativeTimedOut ? .timedOut : .failed
        try journal.transition(
            operationID: operationID,
            to: first,
            at: baseDate.addingTimeInterval(1)
        )
        if scenario == .nativeDeadLetter {
            try journal.transition(
                operationID: operationID,
                to: .deadLetter,
                at: baseDate.addingTimeInterval(2)
            )
        }
        try publishCommitMarkerAndStop(at: markerURL)
    }

    try journal.transition(
        operationID: operationID,
        to: .targetLoaded,
        at: baseDate.addingTimeInterval(1)
    )
    try stopIfNeeded(scenario, is: .nativeTargetLoaded, markerURL: markerURL)

    try journal.enqueueContinuation(outboxEntry(id: operationID))
    try stopIfNeeded(scenario, is: .nativeContinuationSent, markerURL: markerURL)

    _ = try journal.beginOutboxDeliveryAttempt(
        messageID: operationID,
        at: baseDate.addingTimeInterval(3)
    )
    try stopIfNeeded(scenario, is: .nativeDeliveryAttempt, markerURL: markerURL)

    try journal.recordDeliveryReceipt(receipt(id: operationID))
    try stopIfNeeded(scenario, is: .nativeDeliveryReceipt, markerURL: markerURL)

    if scenario == .nativeAcknowledged {
        try journal.acknowledgeOperation(
            operationID: operationID,
            at: baseDate.addingTimeInterval(5)
        )
        try publishCommitMarkerAndStop(at: markerURL)
    }
    try journal.transition(
        operationID: operationID,
        to: .monitoring,
        at: baseDate.addingTimeInterval(5)
    )
    try stopIfNeeded(scenario, is: .nativeMonitoring, markerURL: markerURL)
    try journal.transition(
        operationID: operationID,
        to: .waitingUser,
        at: baseDate.addingTimeInterval(6)
    )
    try publishCommitMarkerAndStop(at: markerURL)
}

private func writeHardAndStop(
    journal: GuardianJournal,
    scenario: CrashScenario,
    operationID: UUID,
    markerURL: URL
) throws -> Never {
    let lease = try journal.acquireLease(
        resource: "desktop-restart",
        ownerID: operationID,
        now: baseDate,
        duration: 60
    )
    try journal.transition(
        operationID: operationID,
        expectedPhase: .prepared,
        to: .gated,
        lease: lease,
        at: baseDate.addingTimeInterval(1)
    )
    try stopIfNeeded(scenario, is: .hardGated, markerURL: markerURL)

    let identity = GuardianDesktopProcessIdentity(
        bundleIdentifier: "com.openai.codex",
        bundleURLPath: "/Applications/Codex.app",
        signingIdentifier: "com.openai.codex",
        teamIdentifier: "OPENAI",
        processID: 4321,
        processStartIdentity: 98_765,
        serverGeneration: 7
    )
    try journal.storeRestartFence(
        operationID: operationID,
        identity: identity,
        lease: lease,
        at: baseDate.addingTimeInterval(2)
    )
    _ = try journal.issueRestart(
        operationID: operationID,
        observedIdentity: identity,
        lease: lease,
        at: baseDate.addingTimeInterval(3)
    )
    try stopIfNeeded(scenario, is: .hardRestartIssued, markerURL: markerURL)

    let phases: [(CrashScenario, GuardianOperationPhase, GuardianOperationPhase, TimeInterval)] = [
        (.hardDesktopStarted, .restartIssued, .desktopStarted, 4),
        (.hardControlReady, .desktopStarted, .controlReady, 5),
        (.hardTargetLoaded, .controlReady, .targetLoaded, 6),
    ]
    for (checkpoint, expected, next, offset) in phases {
        try journal.transition(
            operationID: operationID,
            expectedPhase: expected,
            to: next,
            lease: lease,
            at: baseDate.addingTimeInterval(offset)
        )
        try stopIfNeeded(scenario, is: checkpoint, markerURL: markerURL)
    }
    try publishCommitMarkerAndStop(at: markerURL)
}

private func writeRollbackAndStop(
    databaseURL: URL,
    scenario: CrashScenario,
    operationID: UUID,
    markerURL: URL
) throws -> Never {
    guard let faultPoint = scenario.faultPoint else {
        throw WorkerError.assertion("missing rollback fault point")
    }
    let setup = try GuardianJournal(databaseURL: databaseURL)
    if scenario != .rollbackCreate {
        try setup.create(operation(id: operationID, kind: .nativeRecovery))
    }
    if scenario == .rollbackOutboxEnqueue
        || scenario == .rollbackReceipt
        || scenario == .rollbackAcknowledgement {
        try setup.transition(
            operationID: operationID,
            to: .targetLoaded,
            at: baseDate.addingTimeInterval(1)
        )
    }
    if scenario == .rollbackReceipt || scenario == .rollbackAcknowledgement {
        try setup.enqueueContinuation(outboxEntry(id: operationID))
        _ = try setup.beginOutboxDeliveryAttempt(
            messageID: operationID,
            at: baseDate.addingTimeInterval(3)
        )
    }
    if scenario == .rollbackAcknowledgement {
        try setup.recordDeliveryReceipt(receipt(id: operationID))
    }

    let faulting = try GuardianJournal(
        databaseURL: databaseURL,
        faultInjector: rollbackFaultInjector(target: faultPoint, markerURL: markerURL)
    )
    switch scenario {
    case .rollbackCreate:
        try faulting.create(operation(id: operationID, kind: .nativeRecovery))
    case .rollbackTransition:
        try faulting.transition(
            operationID: operationID,
            to: .targetLoaded,
            at: baseDate.addingTimeInterval(1)
        )
    case .rollbackOutboxEnqueue:
        try faulting.enqueueContinuation(outboxEntry(id: operationID))
    case .rollbackReceipt:
        try faulting.recordDeliveryReceipt(receipt(id: operationID))
    case .rollbackAcknowledgement:
        try faulting.acknowledgeOperation(
            operationID: operationID,
            at: baseDate.addingTimeInterval(5)
        )
    default:
        throw WorkerError.assertion("invalid rollback scenario")
    }
    throw WorkerError.assertion("fault injector did not stop writer")
}

private func authorityProof() -> GuardianAuthorityCutoverProof {
    GuardianAuthorityCutoverProof(
        desktopControlEvidenceID: "crash-gate0",
        observerComparisonEvidenceID: "crash-comparison",
        deploymentID: "crash-deployment",
        daemonGeneration: 1
    )
}

private func writeAuthorityAndStop(
    databaseURL: URL,
    scenario: CrashScenario,
    operationID: UUID,
    markerURL: URL
) throws -> Never {
    let setup = try GuardianJournal(databaseURL: databaseURL)
    try setup.replaceTaskSnapshots(
        [],
        serverGeneration: 7,
        eventSequence: 42,
        capturedAt: baseDate.addingTimeInterval(-1),
        expiresAt: baseDate.addingTimeInterval(120),
        inventoryCompleteness: .complete
    )
    _ = try setup.beginDaemonGeneration(at: baseDate.addingTimeInterval(-1))
    let lease = try setup.acquireLease(
        resource: GuardianAuthorityFence.cutoverLeaseResource,
        ownerID: operationID,
        now: baseDate,
        duration: 60
    )
    let proof = authorityProof()

    switch scenario {
    case .authorityPrepared:
        _ = try setup.prepareAuthorityCutover(
            proof: proof,
            lease: lease,
            at: baseDate.addingTimeInterval(1)
        )
        try publishCommitMarkerAndStop(at: markerURL)
    case .authorityActivated:
        let prepared = try setup.prepareAuthorityCutover(
            proof: proof,
            lease: lease,
            at: baseDate.addingTimeInterval(1)
        )
        _ = try setup.activateAuthorityCutover(
            expectedEpoch: prepared.epoch,
            lease: lease,
            at: baseDate.addingTimeInterval(2)
        )
        try publishCommitMarkerAndStop(at: markerURL)
    case .rollbackAuthorityPrepare, .rollbackAuthorityActivate:
        guard let faultPoint = scenario.faultPoint else {
            throw WorkerError.assertion("missing authority rollback fault point")
        }
        var preparedEpoch: Int64?
        if scenario == .rollbackAuthorityActivate {
            preparedEpoch = try setup.prepareAuthorityCutover(
                proof: proof,
                lease: lease,
                at: baseDate.addingTimeInterval(1)
            ).epoch
        }
        let faulting = try GuardianJournal(
            databaseURL: databaseURL,
            faultInjector: rollbackFaultInjector(target: faultPoint, markerURL: markerURL)
        )
        if let preparedEpoch {
            _ = try faulting.activateAuthorityCutover(
                expectedEpoch: preparedEpoch,
                lease: lease,
                at: baseDate.addingTimeInterval(2)
            )
        } else {
            _ = try faulting.prepareAuthorityCutover(
                proof: proof,
                lease: lease,
                at: baseDate.addingTimeInterval(1)
            )
        }
        throw WorkerError.assertion("authority fault injector did not stop writer")
    default:
        throw WorkerError.assertion("invalid authority scenario")
    }
}

private func writeRemoteAndStop(
    databaseURL: URL,
    scenario: CrashScenario,
    deviceID: UUID,
    markerURL: URL
) throws -> Never {
    let challenge = remoteChallenge()
    let device = remoteDevice(id: deviceID)
    let setup = try GuardianJournal(databaseURL: databaseURL)
    try setup.issuePairingChallenge(challenge, issuedAt: baseDate)

    if scenario == .rollbackRemotePairing {
        guard let faultPoint = scenario.faultPoint else {
            throw WorkerError.assertion("missing remote pairing fault point")
        }
        let faulting = try GuardianJournal(
            databaseURL: databaseURL,
            faultInjector: rollbackFaultInjector(target: faultPoint, markerURL: markerURL)
        )
        try faulting.pairRemoteDevice(
            device,
            challenge: challenge,
            at: baseDate.addingTimeInterval(1)
        )
        throw WorkerError.assertion("remote pairing fault injector did not stop writer")
    }

    try setup.pairRemoteDevice(
        device,
        challenge: challenge,
        at: baseDate.addingTimeInterval(1)
    )
    var completionLease: GuardianRemoteCommandLease?
    if scenario == .rollbackRemoteCompletion
        || scenario == .rollbackRemoteClaim
        || scenario == .rollbackRemotePrepare
        || scenario == .rollbackRemoteInvoke
        || scenario == .rollbackRemoteAck {
        guard case .accepted = try setup.reconcileRemoteCommand(
            remoteCommand(deviceID: deviceID),
            sealedPayload: remoteSealedPayload(),
            currentGeneration: 7,
            now: baseDate.addingTimeInterval(2)
        ) else {
            throw WorkerError.assertion("remote command was not accepted before completion")
        }
        if scenario == .rollbackRemoteCompletion
            || scenario == .rollbackRemotePrepare
            || scenario == .rollbackRemoteInvoke
            || scenario == .rollbackRemoteAck {
            completionLease = try setup.claimNextRemoteCommand(
                ownerID: UUID(uuidString: "70000000-0000-0000-0000-000000000006")!,
                currentDaemonGeneration: 7,
                now: baseDate.addingTimeInterval(2.5),
                leaseDuration: 1
            )
        }
    }
    var effectPreparation: GuardianRemoteEffectPreparation?
    if scenario == .rollbackRemoteInvoke, let completionLease {
        effectPreparation = try setup.prepareRemoteCommandEffect(
            completionLease,
            adapter: GuardianAdapterIdentity(id: "crash-adapter", version: "1"),
            fences: GuardianRemoteEffectFences(
                authorityEpoch: 1,
                policyEpoch: 1,
                targetRevision: "crash-target"
            ),
            evidenceID: "crash-evidence",
            at: baseDate.addingTimeInterval(3)
        )
    }
    if scenario == .rollbackRemoteAck, let completionLease {
        _ = try setup.completeRemoteCommand(
            completionLease,
            completion: .applied,
            at: baseDate.addingTimeInterval(3)
        )
    }
    guard scenario != .remoteCommandAccepted else {
        guard case .accepted = try setup.reconcileRemoteCommand(
            remoteCommand(deviceID: deviceID),
            sealedPayload: remoteSealedPayload(),
            currentGeneration: 7,
            now: baseDate.addingTimeInterval(2)
        ) else {
            throw WorkerError.assertion("remote command was not accepted")
        }
        try publishCommitMarkerAndStop(at: markerURL)
    }

    guard let faultPoint = scenario.faultPoint else {
        throw WorkerError.assertion("missing remote fault point")
    }
    let faulting = try GuardianJournal(
        databaseURL: databaseURL,
        faultInjector: rollbackFaultInjector(target: faultPoint, markerURL: markerURL)
    )
    switch scenario {
    case .rollbackRemoteAcceptance, .rollbackRemoteQueue:
        _ = try faulting.reconcileRemoteCommand(
            remoteCommand(deviceID: deviceID),
            sealedPayload: remoteSealedPayload(),
            currentGeneration: 7,
            now: baseDate.addingTimeInterval(2)
        )
    case .rollbackRemoteRevocation:
        _ = try faulting.revokeRemoteDevice(
            id: deviceID,
            expectedRevocationEpoch: 0,
            at: baseDate.addingTimeInterval(2)
        )
    case .rollbackRemoteCompletion:
        guard let completionLease else {
            throw WorkerError.assertion("remote completion lease was not claimed")
        }
        _ = try faulting.completeRemoteCommand(
            completionLease,
            completion: .applied,
            at: baseDate.addingTimeInterval(3)
        )
    case .rollbackRemoteClaim:
        _ = try faulting.claimNextRemoteCommand(
            ownerID: UUID(uuidString: "70000000-0000-0000-0000-000000000004")!,
            currentDaemonGeneration: 7,
            now: baseDate.addingTimeInterval(3),
            leaseDuration: 10
        )
    case .rollbackRemotePrepare:
        guard let completionLease else {
            throw WorkerError.assertion("remote preparation lease was not claimed")
        }
        _ = try faulting.prepareRemoteCommandEffect(
            completionLease,
            adapter: GuardianAdapterIdentity(id: "crash-adapter", version: "1"),
            fences: GuardianRemoteEffectFences(
                authorityEpoch: 1,
                policyEpoch: 1,
                targetRevision: "crash-target"
            ),
            evidenceID: "crash-evidence",
            at: baseDate.addingTimeInterval(3)
        )
    case .rollbackRemoteInvoke:
        guard let effectPreparation else {
            throw WorkerError.assertion("remote effect was not prepared")
        }
        _ = try faulting.markRemoteCommandInvoked(
            effectPreparation,
            at: baseDate.addingTimeInterval(3.25)
        )
    case .rollbackRemoteAck:
        _ = try faulting.ackRemoteCommandOutcome(
            deviceID: deviceID,
            commandID: remoteCommand(deviceID: deviceID).commandID,
            at: baseDate.addingTimeInterval(4)
        )
    default:
        throw WorkerError.assertion("invalid remote rollback scenario")
    }
    throw WorkerError.assertion("remote fault injector did not stop writer")
}

private func writeAndStop(
    databaseURL: URL,
    scenario: CrashScenario,
    operationID: UUID,
    markerURL: URL
) throws -> Never {
    if scenario.isDaemonEventScenario {
        try writeDaemonEventAndStop(
            databaseURL: databaseURL,
            scenario: scenario,
            markerURL: markerURL
        )
    }
    if scenario.isRemoteScenario {
        try writeRemoteAndStop(
            databaseURL: databaseURL,
            scenario: scenario,
            deviceID: operationID,
            markerURL: markerURL
        )
    }
    if scenario.isAuthorityScenario {
        try writeAuthorityAndStop(
            databaseURL: databaseURL,
            scenario: scenario,
            operationID: operationID,
            markerURL: markerURL
        )
    }
    if scenario.isRollbackProbe {
        try writeRollbackAndStop(
            databaseURL: databaseURL,
            scenario: scenario,
            operationID: operationID,
            markerURL: markerURL
        )
    }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.create(operation(id: operationID, kind: scenario.kind))
    if scenario.expectedPhase == .prepared {
        try publishCommitMarkerAndStop(at: markerURL)
    }
    switch scenario.kind {
    case .nativeRecovery:
        try writeNativeAndStop(
            journal: journal,
            scenario: scenario,
            operationID: operationID,
            markerURL: markerURL
        )
    case .hardRestart:
        try writeHardAndStop(
            journal: journal,
            scenario: scenario,
            operationID: operationID,
            markerURL: markerURL
        )
    }
}

private func verifyDaemonEvent(databaseURL: URL) throws {
    let journal = try GuardianJournal(databaseURL: databaseURL)
    guard let state = try journal.daemonState() else {
        throw WorkerError.assertion("daemon state disappeared")
    }
    try require(state.lastSequence == 0, "partial daemon cursor advance survived")
    let cursor = GuardianIPCEventCursor(generation: state.generation, lastSequence: 0)
    let replay = try journal.replayDaemonEvents(after: cursor)
    try require(
        replay == .events([], nextCursor: cursor),
        "partial daemon event survived"
    )
    let retried = try journal.appendDaemonEvent(
        kind: .taskChanged,
        operationID: nil,
        expectedGeneration: state.generation,
        at: baseDate.addingTimeInterval(2)
    )
    try require(retried.sequence == 1, "rolled-back sequence was not reusable")
    print("verified rollback-daemon-event: event row and cursor are atomic")
}

private func verifyAuthority(
    databaseURL: URL,
    scenario: CrashScenario
) throws {
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let fence = try journal.authorityFence()
    let events = try journal.authorityEvents()
    let operations = try journal.operations()
    try require(operations.isEmpty, "authority cutover created an operation row")

    switch scenario {
    case .authorityPrepared:
        try require(fence.phase == .prepared, "prepared fence was not durable")
        try require(events.count == 1 && events[0].to == .prepared, "prepared audit differed")
    case .authorityActivated:
        try require(fence.phase == .daemonAuthoritative, "activated fence was not durable")
        try require(fence.epoch == 1, "activated epoch differed")
        try require(events.count == 2, "activated audit count differed")
        try require(events.last?.to == .daemonAuthoritative, "activated audit missing")
        do {
            _ = try journal.issueAuthorityPermit(owner: .legacy, at: baseDate.addingTimeInterval(3))
            throw WorkerError.assertion("legacy retained authority after activation")
        } catch let error as GuardianAuthorityFenceError {
            try require(error == .authorityDenied(.legacy), "legacy denial differed: \(error)")
        }
        _ = try journal.issueAuthorityPermit(owner: .daemon, at: baseDate.addingTimeInterval(3))
    case .rollbackAuthorityPrepare:
        try require(fence.phase == .legacyAuthoritative, "partial prepare survived")
        try require(fence.epoch == 0, "partial prepare changed epoch")
        try require(events.isEmpty, "partial prepare audit survived")
    case .rollbackAuthorityActivate:
        try require(fence.phase == .prepared, "partial activation survived")
        try require(fence.epoch == 0, "partial activation changed epoch")
        try require(events.count == 1 && events[0].to == .prepared, "partial activation audit survived")
    default:
        throw WorkerError.assertion("invalid authority verification scenario")
    }
    print("verified \(scenario.rawValue): authority fence and audit are atomic")
}

private func verifyRemote(
    databaseURL: URL,
    scenario: CrashScenario,
    deviceID: UUID
) throws {
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let device = remoteDevice(id: deviceID)
    let command = remoteCommand(deviceID: deviceID)

    switch scenario {
    case .rollbackRemotePairing:
        let beforeRetry = try journal.remoteDevice(id: deviceID)
        try require(beforeRetry == nil, "partial device trust survived")
        try journal.pairRemoteDevice(
            device,
            challenge: remoteChallenge(),
            at: baseDate.addingTimeInterval(1)
        )
        let afterRetry = try journal.remoteDevice(id: deviceID)
        try require(afterRetry == device, "pairing challenge was consumed")
    case .rollbackRemoteAcceptance, .rollbackRemoteQueue:
        let stored = try journal.remoteDevice(id: deviceID)
        try require(
            stored?.lastAcceptedSequence == 0,
            "partial remote sequence survived"
        )
        guard case .accepted = try journal.reconcileRemoteCommand(
            command,
            sealedPayload: remoteSealedPayload(),
            currentGeneration: 7,
            now: baseDate.addingTimeInterval(2)
        ) else {
            throw WorkerError.assertion("rolled-back remote command was not retryable")
        }
    case .rollbackRemoteRevocation:
        let stored = try journal.remoteDevice(id: deviceID)
        try require(stored?.status == .active, "partial revocation survived")
        try require(stored?.revocationEpoch == 0, "partial revocation epoch survived")
        _ = try journal.revokeRemoteDevice(
            id: deviceID,
            expectedRevocationEpoch: 0,
            at: baseDate.addingTimeInterval(2)
        )
    case .rollbackRemoteCompletion:
        let pending = try journal.remoteCommandOutcome(commandID: command.commandID)
        try require(pending?.state == .pending, "partial terminal outcome survived")
        guard let lease = try journal.claimNextRemoteCommand(
            ownerID: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            currentDaemonGeneration: 7,
            now: baseDate.addingTimeInterval(4),
            leaseDuration: 10
        ) else {
            throw WorkerError.assertion("rolled-back completion was not reclaimable")
        }
        _ = try journal.completeRemoteCommand(
            lease,
            completion: .applied,
            at: baseDate.addingTimeInterval(5)
        )
    case .rollbackRemoteClaim:
        let lease = try journal.claimNextRemoteCommand(
            ownerID: UUID(uuidString: "70000000-0000-0000-0000-000000000005")!,
            currentDaemonGeneration: 7,
            now: baseDate.addingTimeInterval(4),
            leaseDuration: 10
        )
        try require(lease?.leaseGeneration == 1, "partial lease generation survived")
        try require(lease?.attemptCount == 1, "partial attempt count survived")
    case .rollbackRemotePrepare:
        let lease = try journal.claimNextRemoteCommand(
            ownerID: UUID(uuidString: "70000000-0000-0000-0000-000000000008")!,
            currentDaemonGeneration: 7,
            now: baseDate.addingTimeInterval(4),
            leaseDuration: 10
        )
        try require(lease?.leaseGeneration == 2, "rolled-back preparation was not reclaimed")
        try require(lease?.attemptCount == 2, "rolled-back preparation changed attempt replay")
    case .rollbackRemoteInvoke:
        let ordinary = try journal.claimNextRemoteCommand(
            ownerID: UUID(),
            currentDaemonGeneration: 7,
            now: baseDate.addingTimeInterval(4),
            leaseDuration: 10
        )
        try require(ordinary == nil, "prepared effect returned to ordinary queue")
        let reconciliation = try journal.claimRemoteCommandForReconciliation(
            ownerID: UUID(uuidString: "70000000-0000-0000-0000-000000000009")!,
            currentDaemonGeneration: 8,
            now: baseDate.addingTimeInterval(4),
            leaseDuration: 10
        )
        try require(reconciliation?.lease.attemptCount == 1, "invocation rollback changed attempt")
        try require(reconciliation?.idempotencyKey == command.commandID, "idempotency key changed")
    case .rollbackRemoteAck:
        let payloadBeforeRetry = try journal.remoteCommandPayload(
            commandID: command.commandID
        )
        try require(
            payloadBeforeRetry != nil,
            "partial ACK destroyed payload"
        )
        _ = try journal.ackRemoteCommandOutcome(
            deviceID: deviceID,
            commandID: command.commandID,
            at: baseDate.addingTimeInterval(5)
        )
        let payloadAfterRetry = try journal.remoteCommandPayload(
            commandID: command.commandID
        )
        try require(
            payloadAfterRetry == nil,
            "committed ACK retained payload"
        )
    case .remoteCommandAccepted:
        guard case let .duplicate(receipt) = try journal.reconcileRemoteCommand(
            command,
            sealedPayload: remoteSealedPayload(),
            currentGeneration: 8,
            now: baseDate.addingTimeInterval(3)
        ) else {
            throw WorkerError.assertion("committed remote receipt was not replayed")
        }
        try require(receipt.commandID == command.commandID, "remote receipt identity differed")
    default:
        throw WorkerError.assertion("invalid remote verification scenario")
    }

    let audits = try journal.remoteAuditEvents(limit: 20)
    let acceptedCount = audits.filter { $0.kind == .commandAccepted }.count
    let revokedCount = audits.filter { $0.kind == .deviceRevoked }.count
    let appliedCount = audits.filter { $0.kind == .commandApplied }.count
    let acknowledgedCount = audits.filter { $0.kind == .commandOutcomeAcknowledged }.count
    switch scenario {
    case .rollbackRemotePairing:
        try require(acceptedCount == 0 && revokedCount == 0, "pairing rollback leaked audit")
    case .rollbackRemoteAcceptance, .rollbackRemoteQueue, .remoteCommandAccepted:
        try require(acceptedCount == 1 && revokedCount == 0, "remote acceptance audit differed")
    case .rollbackRemoteRevocation:
        try require(acceptedCount == 0 && revokedCount == 1, "remote revocation audit differed")
    case .rollbackRemoteCompletion:
        try require(
            acceptedCount == 1 && appliedCount == 1 && revokedCount == 0,
            "remote completion audit differed"
        )
    case .rollbackRemoteClaim, .rollbackRemotePrepare, .rollbackRemoteInvoke:
        try require(acceptedCount == 1 && appliedCount == 0, "remote claim audit differed")
    case .rollbackRemoteAck:
        try require(
            acceptedCount == 1 && appliedCount == 1 && acknowledgedCount == 1,
            "remote ACK audit differed"
        )
    default:
        break
    }
    print("verified \(scenario.rawValue): remote transaction is atomic and replayable")
}

private func verify(
    databaseURL: URL,
    scenario: CrashScenario,
    operationID: UUID
) throws {
    if scenario.isDaemonEventScenario {
        try verifyDaemonEvent(databaseURL: databaseURL)
        return
    }
    if scenario.isRemoteScenario {
        try verifyRemote(
            databaseURL: databaseURL,
            scenario: scenario,
            deviceID: operationID
        )
        return
    }
    if scenario.isAuthorityScenario {
        try verifyAuthority(databaseURL: databaseURL, scenario: scenario)
        return
    }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let operations = try journal.operations()
    if scenario == .rollbackCreate {
        try require(operations.isEmpty, "uncommitted operation survived")
        print("verified \(scenario.rawValue): partial transaction rolled back")
        return
    }
    try require(operations.count == 1, "expected one operation, found \(operations.count)")
    let stored = try journal.operation(id: operationID)
    try require(stored?.phase == scenario.expectedPhase, "expected phase \(scenario.expectedPhase.rawValue), found \(stored?.phase.rawValue ?? "missing")")
    let eventPhases = try journal.events(operationID: operationID).map(\.phase)
    try require(eventPhases == scenario.expectedEvents, "event replay differed: \(eventPhases)")

    let entries = try journal.outboxEntries(operationID: operationID)
    switch scenario {
    case .nativeContinuationSent:
        try require(entries.count == 1 && entries[0].state == .pending, "pending outbox was not durable")
        let deliverable = try journal.deliverableOutboxEntries()
        try require(deliverable.count == 1, "pending delivery disappeared")
    case .nativeDeliveryAttempt, .rollbackReceipt:
        try require(entries.count == 1 && entries[0].state == .awaitingReconciliation, "ambiguous attempt state differed")
        try require(entries[0].attemptCount == 1, "attempt count was not durable")
        let deliverable = try journal.deliverableOutboxEntries()
        try require(deliverable.isEmpty, "ambiguous attempt became deliverable")
        let replayed = try journal.beginOutboxDeliveryAttempt(
            messageID: operationID,
            at: baseDate.addingTimeInterval(10)
        )
        try require(replayed.attemptCount == 1, "ambiguous replay incremented attempt")
    case .nativeDeliveryReceipt, .nativeMonitoring, .nativeWaitingUser,
         .rollbackAcknowledgement:
        try require(entries.count == 1 && entries[0].state == .accepted, "accepted receipt was not durable")
    case .nativeAcknowledged:
        try require(entries.count == 1 && entries[0].state == .acknowledged, "acknowledgement was not durable")
        try require(entries[0].sealedPayload.isEmpty, "acknowledged payload remained")
    default:
        try require(entries.isEmpty, "outbox appeared before continuation")
    }

    print("verified \(scenario.rawValue): phase durable, deliverable duplicates=0")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 4 || arguments.count == 5 else { throw WorkerError.usage }
    guard let scenario = CrashScenario(rawValue: arguments[2]) else {
        throw WorkerError.invalidScenario(arguments[2])
    }
    guard let operationID = UUID(uuidString: arguments[3]) else {
        throw WorkerError.invalidOperationID(arguments[3])
    }

    let databaseURL = URL(fileURLWithPath: arguments[1])
    switch arguments[0] {
    case "write":
        guard arguments.count == 5 else { throw WorkerError.usage }
        try writeAndStop(
            databaseURL: databaseURL,
            scenario: scenario,
            operationID: operationID,
            markerURL: URL(fileURLWithPath: arguments[4])
        )
    case "verify":
        guard arguments.count == 4 else { throw WorkerError.usage }
        try verify(databaseURL: databaseURL, scenario: scenario, operationID: operationID)
    default:
        throw WorkerError.usage
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
