import Foundation

public struct GuardianTaskInventoryItem: Equatable, Codable, Sendable {
    public let taskID: String
    public let signal: TaskEvidenceSignal
    public let confidence: Double

    public init(taskID: String, signal: TaskEvidenceSignal, confidence: Double) {
        self.taskID = taskID
        self.signal = signal
        self.confidence = confidence
    }
}

public struct GuardianTaskInventorySnapshot: Equatable, Codable, Sendable {
    public let serverGeneration: Int64
    public let eventSequence: Int64
    public let observedAt: Date
    public let expiresAt: Date
    public let completeness: TaskInventoryCompleteness
    public let items: [GuardianTaskInventoryItem]

    public init(
        serverGeneration: Int64,
        eventSequence: Int64,
        observedAt: Date,
        expiresAt: Date,
        completeness: TaskInventoryCompleteness,
        items: [GuardianTaskInventoryItem]
    ) {
        self.serverGeneration = serverGeneration
        self.eventSequence = eventSequence
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.completeness = completeness
        self.items = items
    }
}

public struct GuardianTaskLifecycleEvent: Equatable, Codable, Sendable {
    public let taskID: String
    public let signal: TaskEvidenceSignal
    public let serverGeneration: Int64
    public let eventSequence: Int64
    public let observedAt: Date
    public let expiresAt: Date
    public let confidence: Double

    public init(
        taskID: String,
        signal: TaskEvidenceSignal,
        serverGeneration: Int64,
        eventSequence: Int64,
        observedAt: Date,
        expiresAt: Date,
        confidence: Double
    ) {
        self.taskID = taskID
        self.signal = signal
        self.serverGeneration = serverGeneration
        self.eventSequence = eventSequence
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.confidence = confidence
    }
}

public struct GuardianProjectedTask: Equatable, Codable, Sendable {
    public let taskID: String
    public let state: AuthoritativeTaskState
    public let reason: TaskStateClassificationReason
    public let confidence: Double
    public let observedAt: Date
    public let expiresAt: Date

    public init(
        taskID: String,
        state: AuthoritativeTaskState,
        reason: TaskStateClassificationReason,
        confidence: Double,
        observedAt: Date,
        expiresAt: Date
    ) {
        self.taskID = taskID
        self.state = state
        self.reason = reason
        self.confidence = confidence
        self.observedAt = observedAt
        self.expiresAt = expiresAt
    }
}

public struct GuardianProjectedInventory: Equatable, Codable, Sendable {
    public let serverGeneration: Int64
    public let eventSequence: Int64
    public let capturedAt: Date
    public let tasks: [String: GuardianProjectedTask]

    public init(
        serverGeneration: Int64,
        eventSequence: Int64,
        capturedAt: Date,
        tasks: [String: GuardianProjectedTask]
    ) {
        self.serverGeneration = serverGeneration
        self.eventSequence = eventSequence
        self.capturedAt = capturedAt
        self.tasks = tasks
    }
}

public enum GuardianTaskProjectionResnapshotReason: Equatable, Codable, Sendable {
    case incompleteInventory
    case invalidSnapshot
    case generationChanged(expected: Int64, observed: Int64)
    case sequenceGap(expected: Int64, observed: Int64)
    case unknownTask(String)
    case historyLimit
}

public enum GuardianTaskProjectionResult: Equatable, Sendable {
    case applied(GuardianProjectedInventory)
    case resnapshotRequired(GuardianTaskProjectionResnapshotReason)

    public var inventory: GuardianProjectedInventory? {
        guard case let .applied(inventory) = self else { return nil }
        return inventory
    }
}

public actor GuardianTaskProjectionEngine {
    private let journal: GuardianJournal
    private let classifier: TaskStateClassifier
    private let maximumEventsBetweenSnapshots: Int
    private var evidenceByTask: [String: [TaskStateEvidence]] = [:]
    private var inventory: GuardianProjectedInventory?
    private var lastEvent: GuardianTaskLifecycleEvent?

    public init(
        journal: GuardianJournal,
        classifier: TaskStateClassifier = TaskStateClassifier(),
        maximumEventsBetweenSnapshots: Int = 1_024
    ) {
        self.journal = journal
        self.classifier = classifier
        self.maximumEventsBetweenSnapshots = maximumEventsBetweenSnapshots
    }

    public func currentInventory() -> GuardianProjectedInventory? { inventory }

    public func applySnapshot(
        _ snapshot: GuardianTaskInventorySnapshot,
        now: Date = Date()
    ) throws -> GuardianTaskProjectionResult {
        guard snapshot.completeness == .complete else {
            return .resnapshotRequired(.incompleteInventory)
        }
        let ids = snapshot.items.map(\.taskID)
        guard snapshot.serverGeneration > 0,
              snapshot.eventSequence >= 0,
              snapshot.observedAt <= now,
              snapshot.expiresAt > snapshot.observedAt,
              Set(ids).count == ids.count,
              snapshot.items.allSatisfy({
                  !$0.taskID.isEmpty && $0.confidence >= 0 && $0.confidence <= 1
              }) else {
            return .resnapshotRequired(.invalidSnapshot)
        }

        var nextEvidence: [String: [TaskStateEvidence]] = [:]
        for item in snapshot.items {
            nextEvidence[item.taskID] = [TaskStateEvidence(
                taskID: item.taskID,
                source: .appServerSnapshot,
                signal: item.signal,
                observedAt: snapshot.observedAt,
                serverGeneration: snapshot.serverGeneration,
                eventSequence: snapshot.eventSequence,
                confidence: item.confidence,
                expiresAt: snapshot.expiresAt,
                inventoryCompleteness: .complete
            )]
        }
        let projected = project(
            evidenceByTask: nextEvidence,
            generation: snapshot.serverGeneration,
            sequence: snapshot.eventSequence,
            capturedAt: snapshot.observedAt,
            now: now
        )
        try replacePersistedInventory(
            projected,
            evidenceByTask: nextEvidence,
            checkpointExpiresAt: snapshot.expiresAt
        )
        evidenceByTask = nextEvidence
        inventory = projected
        lastEvent = nil
        return .applied(projected)
    }

    public func applyEvent(
        _ event: GuardianTaskLifecycleEvent,
        now: Date = Date()
    ) throws -> GuardianTaskProjectionResult {
        guard let current = inventory else {
            return .resnapshotRequired(.invalidSnapshot)
        }
        guard event.serverGeneration == current.serverGeneration else {
            return .resnapshotRequired(.generationChanged(
                expected: current.serverGeneration,
                observed: event.serverGeneration
            ))
        }
        if event.eventSequence == current.eventSequence, event == lastEvent {
            return .applied(current)
        }
        let expectedSequence = current.eventSequence + 1
        guard event.eventSequence == expectedSequence else {
            return .resnapshotRequired(.sequenceGap(
                expected: expectedSequence,
                observed: event.eventSequence
            ))
        }
        guard evidenceByTask[event.taskID] != nil else {
            return .resnapshotRequired(.unknownTask(event.taskID))
        }
        guard !event.taskID.isEmpty,
              event.observedAt <= now,
              event.expiresAt > event.observedAt,
              event.confidence >= 0,
              event.confidence <= 1 else {
            return .resnapshotRequired(.invalidSnapshot)
        }
        guard (evidenceByTask.values.first?.count ?? 0) < maximumEventsBetweenSnapshots + 1 else {
            return .resnapshotRequired(.historyLimit)
        }

        var nextEvidence = evidenceByTask
        for taskID in nextEvidence.keys {
            guard let previous = nextEvidence[taskID]?.last else { continue }
            let isChangedTask = taskID == event.taskID
            nextEvidence[taskID]?.append(TaskStateEvidence(
                taskID: taskID,
                source: .appServerEvent,
                signal: isChangedTask ? event.signal : previous.signal,
                observedAt: isChangedTask ? event.observedAt : previous.observedAt,
                serverGeneration: event.serverGeneration,
                eventSequence: event.eventSequence,
                confidence: isChangedTask ? event.confidence : previous.confidence,
                expiresAt: isChangedTask ? event.expiresAt : previous.expiresAt,
                inventoryCompleteness: .notApplicable
            ))
        }
        let projected = project(
            evidenceByTask: nextEvidence,
            generation: event.serverGeneration,
            sequence: event.eventSequence,
            capturedAt: event.observedAt,
            now: now
        )
        let checkpointExpiresAt = nextEvidence.values
            .compactMap { $0.last?.expiresAt }
            .min() ?? event.expiresAt
        try replacePersistedInventory(
            projected,
            evidenceByTask: nextEvidence,
            checkpointExpiresAt: checkpointExpiresAt
        )
        evidenceByTask = nextEvidence
        inventory = projected
        lastEvent = event
        return .applied(projected)
    }

    private func project(
        evidenceByTask: [String: [TaskStateEvidence]],
        generation: Int64,
        sequence: Int64,
        capturedAt: Date,
        now: Date
    ) -> GuardianProjectedInventory {
        var tasks: [String: GuardianProjectedTask] = [:]
        for (taskID, evidence) in evidenceByTask {
            let classification = classifier.classify(now: now, evidence: evidence)
            let latest = evidence.last!
            tasks[taskID] = GuardianProjectedTask(
                taskID: taskID,
                state: classification.state,
                reason: classification.reason,
                confidence: latest.confidence,
                observedAt: latest.observedAt,
                expiresAt: latest.expiresAt
            )
        }
        return GuardianProjectedInventory(
            serverGeneration: generation,
            eventSequence: sequence,
            capturedAt: capturedAt,
            tasks: tasks
        )
    }

    private func persist(
        _ projected: GuardianProjectedInventory,
        evidenceByTask: [String: [TaskStateEvidence]]
    ) throws {
        for task in projected.tasks.values {
            guard let evidence = evidenceByTask[task.taskID]?.last else { continue }
            try journal.storeTaskSnapshot(GuardianStoredTaskSnapshot(
                threadID: task.taskID,
                state: task.state,
                source: evidence.source,
                serverGeneration: projected.serverGeneration,
                eventSequence: projected.eventSequence,
                confidence: task.confidence,
                observedAt: task.observedAt,
                expiresAt: task.expiresAt,
                inventoryCompleteness: .complete
            ))
        }
    }

    private func replacePersistedInventory(
        _ projected: GuardianProjectedInventory,
        evidenceByTask: [String: [TaskStateEvidence]],
        checkpointExpiresAt: Date
    ) throws {
        let snapshots = projected.tasks.values.compactMap { task -> GuardianStoredTaskSnapshot? in
            guard let evidence = evidenceByTask[task.taskID]?.last else { return nil }
            return GuardianStoredTaskSnapshot(
                threadID: task.taskID,
                state: task.state,
                source: evidence.source,
                serverGeneration: projected.serverGeneration,
                eventSequence: projected.eventSequence,
                confidence: task.confidence,
                observedAt: task.observedAt,
                expiresAt: task.expiresAt,
                inventoryCompleteness: .complete
            )
        }
        try journal.replaceTaskSnapshots(
            snapshots,
            serverGeneration: projected.serverGeneration,
            eventSequence: projected.eventSequence,
            capturedAt: projected.capturedAt,
            expiresAt: checkpointExpiresAt,
            inventoryCompleteness: .complete
        )
    }
}
