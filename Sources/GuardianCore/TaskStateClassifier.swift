import Foundation

public enum AuthoritativeTaskState: String, Codable, Sendable {
    case working
    case slow
    case finished
    case recovering
    // Decode compatibility for pre-projector shadow rows.
    case running
    case idle
    case waitingUser
    case stuck
    case unknown
}

public enum TaskEvidenceSource: String, Codable, Sendable {
    case appServerSnapshot
    case appServerEvent
    case guardianRecoveryHeartbeat
}

public enum TaskEvidenceSignal: String, Codable, Hashable, Sendable {
    case quiet
    case idle
    case progress
    case ownedWork
    case requesterWork
    case approvalRequired
    case authenticationRequired
    case permissionRequired
    case stalled
    case recoveryHeartbeat
    case controlResponsive
    case softDeadlineExceeded
    case terminal
    case recoveryOwned
}

public enum TaskInventoryCompleteness: String, Codable, Sendable {
    case complete
    case incomplete
    case notApplicable
}

public struct TaskStateEvidence: Equatable, Codable, Sendable {
    public let taskID: String
    public let source: TaskEvidenceSource
    public let signal: TaskEvidenceSignal
    public let observedAt: Date
    public let serverGeneration: Int64
    public let eventSequence: Int64
    public let confidence: Double
    public let expiresAt: Date
    public let inventoryCompleteness: TaskInventoryCompleteness
    public let isVerifiedRecoveryHeartbeat: Bool

    public init(
        taskID: String,
        source: TaskEvidenceSource,
        signal: TaskEvidenceSignal,
        observedAt: Date,
        serverGeneration: Int64,
        eventSequence: Int64,
        confidence: Double,
        expiresAt: Date,
        inventoryCompleteness: TaskInventoryCompleteness,
        isVerifiedRecoveryHeartbeat: Bool = false
    ) {
        self.taskID = taskID
        self.source = source
        self.signal = signal
        self.observedAt = observedAt
        self.serverGeneration = serverGeneration
        self.eventSequence = eventSequence
        self.confidence = confidence
        self.expiresAt = expiresAt
        self.inventoryCompleteness = inventoryCompleteness
        self.isVerifiedRecoveryHeartbeat = isVerifiedRecoveryHeartbeat
    }
}

public enum TaskStateClassificationReason: String, Codable, Sendable {
    case coherentEvidence
    case requesterWorkObserved
    case noEvidence
    case staleEvidence
    case insufficientConfidence
    case conflictingEvidence
    case serverGenerationMismatch
    case sequenceGap
    case incompleteInventory
    case unverifiedRecoveryHeartbeat
    case incompleteSlowEvidence
}

public struct TaskStateClassification: Equatable, Codable, Sendable {
    public let state: AuthoritativeTaskState
    public let reason: TaskStateClassificationReason
    public let requiresFullSnapshot: Bool
    public let ignoredVerifiedRecoveryHeartbeat: Bool

    public init(
        state: AuthoritativeTaskState,
        reason: TaskStateClassificationReason,
        requiresFullSnapshot: Bool,
        ignoredVerifiedRecoveryHeartbeat: Bool
    ) {
        self.state = state
        self.reason = reason
        self.requiresFullSnapshot = requiresFullSnapshot
        self.ignoredVerifiedRecoveryHeartbeat = ignoredVerifiedRecoveryHeartbeat
    }
}

public struct TaskStateClassifier: Sendable {
    public let minimumConfidence: Double

    public init(minimumConfidence: Double = 0.8) {
        self.minimumConfidence = minimumConfidence
    }

    public func classify(
        now: Date,
        evidence: [TaskStateEvidence]
    ) -> TaskStateClassification {
        guard !evidence.isEmpty else {
            return unknown(.noEvidence, requiresFullSnapshot: true)
        }

        guard evidence.allSatisfy({ $0.observedAt <= now && $0.expiresAt > now }) else {
            return unknown(.staleEvidence, requiresFullSnapshot: true)
        }

        guard evidence.allSatisfy({ $0.confidence >= minimumConfidence && $0.confidence <= 1 }) else {
            return unknown(.insufficientConfidence, requiresFullSnapshot: true)
        }

        let heartbeats = evidence.filter { $0.source == .guardianRecoveryHeartbeat }
        guard heartbeats.allSatisfy({
            $0.signal == .recoveryHeartbeat && $0.isVerifiedRecoveryHeartbeat
        }) else {
            return unknown(.unverifiedRecoveryHeartbeat, requiresFullSnapshot: false)
        }
        let ignoredHeartbeat = !heartbeats.isEmpty
        let serverEvidence = evidence.filter { $0.source != .guardianRecoveryHeartbeat }

        guard !serverEvidence.isEmpty else {
            return unknown(.incompleteInventory, requiresFullSnapshot: true)
        }

        guard Set(serverEvidence.map(\.taskID)).count == 1 else {
            return unknown(.conflictingEvidence, requiresFullSnapshot: true)
        }
        guard Set(serverEvidence.map(\.serverGeneration)).count == 1 else {
            return unknown(.serverGenerationMismatch, requiresFullSnapshot: true)
        }

        let snapshots = serverEvidence.filter { $0.source == .appServerSnapshot }
        guard let latestSnapshot = snapshots.max(by: { $0.eventSequence < $1.eventSequence }),
              latestSnapshot.inventoryCompleteness == .complete else {
            return unknown(.incompleteInventory, requiresFullSnapshot: true)
        }

        let relevant = serverEvidence.filter { $0.eventSequence >= latestSnapshot.eventSequence }
        let grouped = Dictionary(grouping: relevant, by: \.eventSequence)
        for sameSequence in grouped.values {
            let meanings = Set(sameSequence.map { semanticMeaning(of: $0.signal) })
            if meanings.count > 1 {
                return unknown(.conflictingEvidence, requiresFullSnapshot: true)
            }
        }

        let eventSequences = Set(
            relevant
                .filter { $0.source == .appServerEvent && $0.eventSequence > latestSnapshot.eventSequence }
                .map(\.eventSequence)
        ).sorted()
        for (offset, sequence) in eventSequences.enumerated() {
            let expected = latestSnapshot.eventSequence + Int64(offset) + 1
            guard sequence == expected else {
                return unknown(.sequenceGap, requiresFullSnapshot: true)
            }
        }

        let latestSequence = relevant.map(\.eventSequence).max() ?? latestSnapshot.eventSequence
        let latestSignals = relevant
            .filter { $0.eventSequence == latestSequence }
            .map(\.signal)

        let state: AuthoritativeTaskState
        let reason: TaskStateClassificationReason
        if latestSignals.contains(where: isWaitingForUser) {
            state = .waitingUser
            reason = .coherentEvidence
        } else if latestSignals.contains(.requesterWork) {
            state = .working
            reason = .requesterWorkObserved
        } else if latestSignals.contains(.progress) || latestSignals.contains(.ownedWork) {
            state = .working
            reason = .coherentEvidence
        } else if latestSignals.contains(.recoveryOwned) {
            state = .recovering
            reason = .coherentEvidence
        } else if latestSignals.contains(.terminal) {
            state = .finished
            reason = .coherentEvidence
        } else if latestSignals.contains(.stalled) {
            state = .stuck
            reason = .coherentEvidence
        } else if latestSignals.contains(.softDeadlineExceeded)
                    && latestSignals.contains(.controlResponsive) {
            state = .slow
            reason = .coherentEvidence
        } else if latestSignals.contains(.softDeadlineExceeded) {
            return unknown(.incompleteSlowEvidence, requiresFullSnapshot: false)
        } else {
            state = .idle
            reason = .coherentEvidence
        }

        return TaskStateClassification(
            state: state,
            reason: reason,
            requiresFullSnapshot: false,
            ignoredVerifiedRecoveryHeartbeat: ignoredHeartbeat
        )
    }

    private func unknown(
        _ reason: TaskStateClassificationReason,
        requiresFullSnapshot: Bool
    ) -> TaskStateClassification {
        TaskStateClassification(
            state: .unknown,
            reason: reason,
            requiresFullSnapshot: requiresFullSnapshot,
            ignoredVerifiedRecoveryHeartbeat: false
        )
    }

    private func semanticMeaning(of signal: TaskEvidenceSignal) -> AuthoritativeTaskState {
        if isWaitingForUser(signal) { return .waitingUser }
        switch signal {
        case .progress, .ownedWork, .requesterWork:
            return .working
        case .controlResponsive, .softDeadlineExceeded:
            return .slow
        case .terminal:
            return .finished
        case .recoveryOwned:
            return .recovering
        case .stalled:
            return .stuck
        case .quiet, .idle, .recoveryHeartbeat:
            return .idle
        case .approvalRequired, .authenticationRequired, .permissionRequired:
            return .waitingUser
        }
    }

    private func isWaitingForUser(_ signal: TaskEvidenceSignal) -> Bool {
        switch signal {
        case .approvalRequired, .authenticationRequired, .permissionRequired:
            return true
        default:
            return false
        }
    }
}
