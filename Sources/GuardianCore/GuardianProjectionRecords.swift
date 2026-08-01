import Foundation

public struct GuardianTaskProjectionCheckpoint: Equatable, Sendable {
    public let serverGeneration: Int64
    public let eventSequence: Int64
    public let capturedAt: Date
    public let expiresAt: Date
    public let inventoryCompleteness: TaskInventoryCompleteness

    public init(
        serverGeneration: Int64,
        eventSequence: Int64,
        capturedAt: Date,
        expiresAt: Date,
        inventoryCompleteness: TaskInventoryCompleteness
    ) {
        self.serverGeneration = serverGeneration
        self.eventSequence = eventSequence
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.inventoryCompleteness = inventoryCompleteness
    }

    var isValid: Bool {
        serverGeneration > 0
            && eventSequence >= 0
            && capturedAt <= expiresAt
    }
}

public struct GuardianStoredTaskSnapshot: Equatable, Sendable {
    public let threadID: String
    public let state: AuthoritativeTaskState
    public let source: TaskEvidenceSource
    public let serverGeneration: Int64
    public let eventSequence: Int64
    public let confidence: Double
    public let observedAt: Date
    public let expiresAt: Date
    public let inventoryCompleteness: TaskInventoryCompleteness

    public init(
        threadID: String,
        state: AuthoritativeTaskState,
        source: TaskEvidenceSource,
        serverGeneration: Int64,
        eventSequence: Int64,
        confidence: Double,
        observedAt: Date,
        expiresAt: Date,
        inventoryCompleteness: TaskInventoryCompleteness
    ) {
        self.threadID = threadID
        self.state = state
        self.source = source
        self.serverGeneration = serverGeneration
        self.eventSequence = eventSequence
        self.confidence = confidence
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.inventoryCompleteness = inventoryCompleteness
    }

    var isValid: Bool {
        !threadID.isEmpty
            && serverGeneration > 0
            && eventSequence >= 0
            && confidence >= 0
            && confidence <= 1
            && observedAt <= expiresAt
    }
}

public struct GuardianStoredClientSession: Equatable, Sendable {
    public let clientID: UUID
    public let role: GuardianIPCClientRole
    public let generation: Int64
    public let lastAcknowledgedSequence: Int64
    public let updatedAt: Date

    public init(
        clientID: UUID,
        role: GuardianIPCClientRole,
        generation: Int64,
        lastAcknowledgedSequence: Int64,
        updatedAt: Date
    ) {
        self.clientID = clientID
        self.role = role
        self.generation = generation
        self.lastAcknowledgedSequence = lastAcknowledgedSequence
        self.updatedAt = updatedAt
    }

    var cursor: GuardianIPCEventCursor {
        GuardianIPCEventCursor(
            generation: generation,
            lastSequence: lastAcknowledgedSequence
        )
    }

    var isValid: Bool {
        generation > 0 && lastAcknowledgedSequence >= 0
    }
}

public struct GuardianStoredIncident: Equatable, Sendable {
    public let id: UUID
    public let operationID: UUID?
    public let family: RepairFailureFamily
    public let nature: RepairFailureNature
    public let symptomCode: String
    public let changedVariable: String?
    public let evidenceID: String
    public let result: RepairAttemptResult
    public let occurredAt: Date

    public init(
        id: UUID,
        operationID: UUID?,
        family: RepairFailureFamily,
        nature: RepairFailureNature,
        symptomCode: String,
        changedVariable: String?,
        evidenceID: String,
        result: RepairAttemptResult,
        occurredAt: Date
    ) {
        self.id = id
        self.operationID = operationID
        self.family = family
        self.nature = nature
        self.symptomCode = symptomCode
        self.changedVariable = changedVariable
        self.evidenceID = evidenceID
        self.result = result
        self.occurredAt = occurredAt
    }

    var isValid: Bool {
        !symptomCode.isEmpty
            && !evidenceID.isEmpty
            && changedVariable?.isEmpty != true
    }
}
