import Foundation

public enum GuardianSafePointBarrierMutation: Equatable, Sendable {
    case upsert(SafePointTaskObservation)
    case remove(threadID: String)
}

public struct GuardianSafePointBarrierEvent: Equatable, Sendable {
    public let generation: Int64
    public let sequence: Int64
    public let observedAt: Date
    public let mutation: GuardianSafePointBarrierMutation

    public init(
        generation: Int64,
        sequence: Int64,
        observedAt: Date,
        mutation: GuardianSafePointBarrierMutation
    ) {
        self.generation = generation
        self.sequence = sequence
        self.observedAt = observedAt
        self.mutation = mutation
    }
}

public struct GuardianSafePointBarrierSnapshot: Equatable, Sendable {
    public let inventory: SafePointInventory
    public let lastSequence: Int64

    public init(inventory: SafePointInventory, lastSequence: Int64) {
        self.inventory = inventory
        self.lastSequence = lastSequence
    }
}

public enum GuardianSafePointBoundaryCapability: Equatable, Sendable {
    case unavailable
    case serialized(generation: Int64)
}

public struct GuardianSafePointBarrierReceipt: Equatable, Sendable {
    public let operationID: UUID
    public let generation: Int64
    public let throughSequence: Int64
    public let issuedAt: Date

    public init(
        operationID: UUID,
        generation: Int64,
        throughSequence: Int64,
        issuedAt: Date
    ) {
        self.operationID = operationID
        self.generation = generation
        self.throughSequence = throughSequence
        self.issuedAt = issuedAt
    }
}

public enum GuardianSafePointBarrierResult: Equatable, Sendable {
    case issued(GuardianSafePointBarrierReceipt)
    case denied(SafePointDecision)
}

public actor GuardianSafePointBarrier {
    private let policy: SafePointPolicy
    private var inventory: SafePointInventory?
    private var lastSequence: Int64?
    private var observedGenerationMismatch: Int64?

    public init(maximumSnapshotAge: TimeInterval) {
        policy = SafePointPolicy(maximumSnapshotAge: maximumSnapshotAge)
    }

    public func install(_ snapshot: GuardianSafePointBarrierSnapshot) {
        guard snapshot.lastSequence >= 0, snapshot.inventory.generation > 0 else {
            inventory = nil
            lastSequence = nil
            observedGenerationMismatch = nil
            return
        }
        var unique: [String: SafePointTaskObservation] = [:]
        var conflict = snapshot.inventory.hasConflictingEvidence
        for task in snapshot.inventory.tasks {
            guard !task.threadID.isEmpty else {
                conflict = true
                continue
            }
            if let existing = unique[task.threadID], existing != task {
                conflict = true
            }
            unique[task.threadID] = task
        }
        inventory = replacing(
            snapshot.inventory,
            tasks: unique.values.sorted { $0.threadID < $1.threadID },
            hasConflictingEvidence: conflict
        )
        lastSequence = snapshot.lastSequence
        observedGenerationMismatch = nil
    }

    public func ingest(_ event: GuardianSafePointBarrierEvent) {
        apply(event)
    }

    public func attemptRestart(
        request: SafePointRequest,
        boundary: GuardianSafePointBoundaryCapability,
        now: Date = Date(),
        drainBufferedEvents: @Sendable () -> [GuardianSafePointBarrierEvent],
        issueRestart: @Sendable (GuardianSafePointBarrierReceipt) -> Void
    ) -> GuardianSafePointBarrierResult {
        guard case let .serialized(boundaryGeneration) = boundary else {
            return .denied(.blocked(.unknown(.atomicBoundaryUnavailable)))
        }
        guard let currentInventory = inventory else {
            return .denied(.blocked(.unknown(.incompleteInventory)))
        }
        guard boundaryGeneration == currentInventory.generation else {
            return .denied(.resnapshotRequired(
                expectedGeneration: request.expectedGeneration,
                observedGeneration: boundaryGeneration
            ))
        }

        for event in drainBufferedEvents() {
            apply(event)
        }
        if let observedGenerationMismatch {
            return .denied(.resnapshotRequired(
                expectedGeneration: request.expectedGeneration,
                observedGeneration: observedGenerationMismatch
            ))
        }
        guard let inventory, let lastSequence else {
            return .denied(.blocked(.unknown(.incompleteInventory)))
        }
        let decision = policy.decision(request: request, inventory: inventory, now: now)
        guard decision == .automaticRestartAllowed else {
            return .denied(decision)
        }

        let receipt = GuardianSafePointBarrierReceipt(
            operationID: request.operationID,
            generation: inventory.generation,
            throughSequence: lastSequence,
            issuedAt: now
        )
        // This closure is synchronous. Actor isolation cannot yield between the final
        // drain, policy decision, and the destructive boundary.
        issueRestart(receipt)
        return .issued(receipt)
    }

    private func apply(_ event: GuardianSafePointBarrierEvent) {
        guard var inventory, let lastSequence else { return }
        guard event.generation == inventory.generation else {
            observedGenerationMismatch = event.generation
            return
        }
        guard inventory.sequenceIsContiguous,
              event.sequence == lastSequence + 1 else {
            self.inventory = replacing(inventory, sequenceIsContiguous: false)
            return
        }

        var tasks = Dictionary(uniqueKeysWithValues: inventory.tasks.map { ($0.threadID, $0) })
        switch event.mutation {
        case let .upsert(task):
            guard !task.threadID.isEmpty else {
                self.inventory = replacing(inventory, hasConflictingEvidence: true)
                return
            }
            tasks[task.threadID] = task
        case let .remove(threadID):
            guard !threadID.isEmpty else {
                self.inventory = replacing(inventory, hasConflictingEvidence: true)
                return
            }
            tasks.removeValue(forKey: threadID)
        }
        inventory = replacing(
            inventory,
            tasks: tasks.values.sorted { $0.threadID < $1.threadID },
            capturedAt: max(inventory.capturedAt, event.observedAt)
        )
        self.inventory = inventory
        self.lastSequence = event.sequence
    }

    private func replacing(
        _ inventory: SafePointInventory,
        tasks: [SafePointTaskObservation]? = nil,
        capturedAt: Date? = nil,
        sequenceIsContiguous: Bool? = nil,
        hasConflictingEvidence: Bool? = nil
    ) -> SafePointInventory {
        SafePointInventory(
            tasks: tasks ?? inventory.tasks,
            capturedAt: capturedAt ?? inventory.capturedAt,
            generation: inventory.generation,
            schemaIsSupported: inventory.schemaIsSupported,
            isComplete: inventory.isComplete,
            sequenceIsContiguous: sequenceIsContiguous ?? inventory.sequenceIsContiguous,
            hasConflictingEvidence: hasConflictingEvidence ?? inventory.hasConflictingEvidence
        )
    }
}
