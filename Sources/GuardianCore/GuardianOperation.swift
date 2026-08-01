import Foundation

public enum GuardianOperationKind: String, Codable, Equatable, Sendable {
    case nativeRecovery
    case hardRestart
}

public enum GuardianOperationPhase: String, Codable, Equatable, Sendable {
    case prepared
    case gated
    case restartIssued
    case desktopStarted
    case controlReady
    case targetLoaded
    case continuationSent
    case deliveryReceipt
    case monitoring
    case waitingUser
    case acknowledged
    case failed
    case timedOut
    case deadLetter
}

public struct GuardianOperation: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: GuardianOperationKind
    public let originThreadID: String
    public let originTokenHash: String
    public let phase: GuardianOperationPhase
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        kind: GuardianOperationKind,
        originThreadID: String,
        originTokenHash: String,
        phase: GuardianOperationPhase,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.originThreadID = originThreadID
        self.originTokenHash = originTokenHash
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func advancing(
        to phase: GuardianOperationPhase,
        at date: Date
    ) -> GuardianOperation {
        GuardianOperation(
            id: id,
            kind: kind,
            originThreadID: originThreadID,
            originTokenHash: originTokenHash,
            phase: phase,
            createdAt: createdAt,
            updatedAt: date
        )
    }
}

public enum GuardianEventActor: String, Codable, Equatable, Sendable {
    case client
    case daemon
    case codex
    case system
}

public struct GuardianTransitionContext: Equatable, Sendable {
    public let actor: GuardianEventActor
    public let reason: String
    public let serverGeneration: Int64?
    public let evidenceID: String?

    public init(
        actor: GuardianEventActor,
        reason: String,
        serverGeneration: Int64? = nil,
        evidenceID: String? = nil
    ) {
        self.actor = actor
        self.reason = reason
        self.serverGeneration = serverGeneration
        self.evidenceID = evidenceID
    }

    public static let phaseTransition = GuardianTransitionContext(
        actor: .daemon,
        reason: "phase.transition"
    )
}

public struct GuardianOperationEvent: Equatable, Sendable {
    public let operationID: UUID
    public let index: Int
    public let phase: GuardianOperationPhase
    public let occurredAt: Date
    public let actor: GuardianEventActor
    public let reason: String
    public let serverGeneration: Int64?
    public let evidenceID: String?

    public init(
        operationID: UUID,
        index: Int,
        phase: GuardianOperationPhase,
        occurredAt: Date,
        actor: GuardianEventActor = .daemon,
        reason: String = "phase.transition",
        serverGeneration: Int64? = nil,
        evidenceID: String? = nil
    ) {
        self.operationID = operationID
        self.index = index
        self.phase = phase
        self.occurredAt = occurredAt
        self.actor = actor
        self.reason = reason
        self.serverGeneration = serverGeneration
        self.evidenceID = evidenceID
    }
}

public struct GuardianLease: Equatable, Sendable {
    public let resource: String
    public let ownerID: UUID
    public let generation: Int64
    public let expiresAt: Date

    public init(
        resource: String,
        ownerID: UUID,
        generation: Int64,
        expiresAt: Date
    ) {
        self.resource = resource
        self.ownerID = ownerID
        self.generation = generation
        self.expiresAt = expiresAt
    }
}

public enum GuardianJournalError: Error, Equatable, Sendable {
    case invalidInitialPhase(GuardianOperationPhase)
    case invalidOriginIdentity
    case duplicateOperationConflict(UUID)
    case originTokenConflict
    case operationNotFound(UUID)
    case invalidTransition(from: GuardianOperationPhase, to: GuardianOperationPhase)
    case leaseRequired
    case leaseBusy(String)
    case staleLease(String)
    case invalidLeaseDuration
    case invalidOutboxEntry
    case outboxConflict(UUID)
    case outboxNotFound(UUID)
    case deliveryReceiptMismatch(UUID)
    case staleRestartCircuitVersion(String)
    case restartFenceConflict(UUID)
    case restartIdentityMismatch(UUID)
    case staleDaemonGeneration(expected: Int64, current: Int64)
    case staleTaskSnapshot(String)
    case staleClientSession(UUID)
    case invalidProjectionRecord
    case invalidRemoteRecord
    case pairingChallengeConflict
    case pairingChallengeNotFound
    case pairingChallengeExpired
    case pairingChallengeConsumed
    case remoteDeviceNotFound(UUID)
    case remoteDeviceConflict(UUID)
    case remoteCommandNotFound(UUID)
    case remoteCommandOutcomeConflict(UUID)
    case remoteOutcomeAcknowledgementDenied(UUID)
    case staleRemoteRevocationEpoch(deviceID: UUID, expected: UInt64, current: UInt64)
    case corruptRemoteTrust
    case corruptStoredOperation
    case storageUnavailable
}

struct GuardianOperationTransitionPolicy: Sendable {
    func allows(
        kind: GuardianOperationKind,
        from: GuardianOperationPhase,
        to: GuardianOperationPhase
    ) -> Bool {
        if from == to { return true }
        let terminal: Set<GuardianOperationPhase> = [.acknowledged, .deadLetter]
        if terminal.contains(from) {
            return false
        }
        if from == .failed || from == .timedOut {
            return to == .deadLetter
        }
        if to == .failed || to == .timedOut {
            return true
        }
        switch from {
        case .prepared:
            switch kind {
            case .nativeRecovery:
                return to == .targetLoaded
            case .hardRestart:
                return to == .gated
            }
        case .gated:
            return to == .restartIssued
        case .restartIssued:
            return to == .desktopStarted
        case .desktopStarted:
            return to == .controlReady
        case .controlReady:
            return to == .targetLoaded
        case .targetLoaded:
            return to == .continuationSent
        case .continuationSent:
            return to == .deliveryReceipt
        case .deliveryReceipt:
            return to == .monitoring || to == .waitingUser || to == .acknowledged
        case .monitoring:
            return to == .waitingUser || to == .acknowledged
        case .waitingUser:
            return to == .monitoring || to == .acknowledged
        case .failed, .timedOut, .acknowledged, .deadLetter:
            return false
        }
    }
}
