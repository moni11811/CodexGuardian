import Foundation

public enum SafePointTaskState: Equatable, Sendable {
    case active
    case idle
}

public struct SafePointHeartbeatProof: Equatable, Sendable {
    public let operationID: UUID
    public let originThreadID: String
    public let originToken: UUID
    public let isVerified: Bool

    public init(
        operationID: UUID,
        originThreadID: String,
        originToken: UUID,
        isVerified: Bool
    ) {
        self.operationID = operationID
        self.originThreadID = originThreadID
        self.originToken = originToken
        self.isVerified = isVerified
    }
}

public enum SafePointActivityRole: Equatable, Sendable {
    case ordinary
    case recoveryHeartbeat(SafePointHeartbeatProof)
}

public struct SafePointTaskObservation: Equatable, Sendable {
    public let threadID: String
    public let state: SafePointTaskState
    public let role: SafePointActivityRole

    public init(
        threadID: String,
        state: SafePointTaskState,
        role: SafePointActivityRole = .ordinary
    ) {
        self.threadID = threadID
        self.state = state
        self.role = role
    }
}

public struct SafePointInventory: Equatable, Sendable {
    public let tasks: [SafePointTaskObservation]
    public let capturedAt: Date
    public let generation: Int64
    public let schemaIsSupported: Bool
    public let isComplete: Bool
    public let sequenceIsContiguous: Bool
    public let hasConflictingEvidence: Bool

    public init(
        tasks: [SafePointTaskObservation],
        capturedAt: Date,
        generation: Int64,
        schemaIsSupported: Bool,
        isComplete: Bool,
        sequenceIsContiguous: Bool,
        hasConflictingEvidence: Bool
    ) {
        self.tasks = tasks
        self.capturedAt = capturedAt
        self.generation = generation
        self.schemaIsSupported = schemaIsSupported
        self.isComplete = isComplete
        self.sequenceIsContiguous = sequenceIsContiguous
        self.hasConflictingEvidence = hasConflictingEvidence
    }
}

public struct SafePointRequest: Equatable, Sendable {
    public let operationID: UUID
    public let originThreadID: String
    public let originToken: UUID
    public let expectedGeneration: Int64
    public let forceBypassRequested: Bool

    public init(
        operationID: UUID,
        originThreadID: String,
        originToken: UUID,
        expectedGeneration: Int64,
        forceBypassRequested: Bool = false
    ) {
        self.operationID = operationID
        self.originThreadID = originThreadID
        self.originToken = originToken
        self.expectedGeneration = expectedGeneration
        self.forceBypassRequested = forceBypassRequested
    }
}

public enum SafePointUnknownReason: Equatable, Sendable {
    case staleSnapshot
    case sequenceGap
    case incompleteInventory
    case unsupportedSchema
    case conflictingEvidence
    case atomicBoundaryUnavailable
}

public enum SafePointBlockReason: Equatable, Sendable {
    case activeTasks([String])
    case unknown(SafePointUnknownReason)
    case humanForceRequired
}

public enum SafePointDecision: Equatable, Sendable {
    case automaticRestartAllowed
    case blocked(SafePointBlockReason)
    case resnapshotRequired(expectedGeneration: Int64, observedGeneration: Int64)
}

public struct SafePointPolicy: Sendable {
    public let maximumSnapshotAge: TimeInterval

    public init(maximumSnapshotAge: TimeInterval) {
        self.maximumSnapshotAge = maximumSnapshotAge
    }

    public func decision(
        request: SafePointRequest,
        inventory: SafePointInventory,
        now: Date = Date()
    ) -> SafePointDecision {
        guard !request.forceBypassRequested else {
            return .blocked(.humanForceRequired)
        }
        guard inventory.schemaIsSupported else {
            return .blocked(.unknown(.unsupportedSchema))
        }
        guard inventory.isComplete else {
            return .blocked(.unknown(.incompleteInventory))
        }
        guard inventory.sequenceIsContiguous else {
            return .blocked(.unknown(.sequenceGap))
        }
        guard !inventory.hasConflictingEvidence else {
            return .blocked(.unknown(.conflictingEvidence))
        }

        let snapshotAge = now.timeIntervalSince(inventory.capturedAt)
        guard snapshotAge >= 0, snapshotAge <= maximumSnapshotAge else {
            return .blocked(.unknown(.staleSnapshot))
        }
        guard inventory.generation == request.expectedGeneration else {
            return .resnapshotRequired(
                expectedGeneration: request.expectedGeneration,
                observedGeneration: inventory.generation
            )
        }

        let blockingThreadIDs = Set(inventory.tasks.compactMap { task -> String? in
            guard task.state == .active else { return nil }
            return isExactVerifiedHeartbeat(task, request: request) ? nil : task.threadID
        }).sorted()
        guard blockingThreadIDs.isEmpty else {
            return .blocked(.activeTasks(blockingThreadIDs))
        }
        return .automaticRestartAllowed
    }

    private func isExactVerifiedHeartbeat(
        _ task: SafePointTaskObservation,
        request: SafePointRequest
    ) -> Bool {
        guard case let .recoveryHeartbeat(proof) = task.role else { return false }
        return proof.isVerified
            && proof.operationID == request.operationID
            && proof.originToken == request.originToken
            && proof.originThreadID == request.originThreadID
            && task.threadID == request.originThreadID
    }
}
