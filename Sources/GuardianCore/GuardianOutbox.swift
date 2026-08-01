import Foundation

public enum GuardianOutboxState: String, Codable, Equatable, Sendable {
    case pending
    case awaitingReconciliation
    case accepted
    case acknowledged
    case deadLetter
}

public struct GuardianDeliveryReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let messageID: UUID
    public let targetThreadID: String
    public let messageItemID: String
    public let turnID: String
    public let acceptedAt: Date

    public init(
        operationID: UUID,
        messageID: UUID,
        targetThreadID: String,
        messageItemID: String,
        turnID: String,
        acceptedAt: Date
    ) {
        self.operationID = operationID
        self.messageID = messageID
        self.targetThreadID = targetThreadID
        self.messageItemID = messageItemID
        self.turnID = turnID
        self.acceptedAt = acceptedAt
    }
}

public struct GuardianOutboxEntry: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let messageID: UUID
    public let targetThreadID: String
    public let sealedPayload: Data
    public let state: GuardianOutboxState
    public let attemptCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let receipt: GuardianDeliveryReceipt?

    public init(
        operationID: UUID,
        messageID: UUID,
        targetThreadID: String,
        sealedPayload: Data,
        state: GuardianOutboxState,
        attemptCount: Int,
        createdAt: Date,
        updatedAt: Date,
        receipt: GuardianDeliveryReceipt?
    ) {
        self.operationID = operationID
        self.messageID = messageID
        self.targetThreadID = targetThreadID
        self.sealedPayload = sealedPayload
        self.state = state
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.receipt = receipt
    }

    func beginningDeliveryAttempt(at date: Date) -> GuardianOutboxEntry {
        GuardianOutboxEntry(
            operationID: operationID,
            messageID: messageID,
            targetThreadID: targetThreadID,
            sealedPayload: sealedPayload,
            state: .awaitingReconciliation,
            attemptCount: attemptCount + 1,
            createdAt: createdAt,
            updatedAt: date,
            receipt: nil
        )
    }

    func accepting(_ receipt: GuardianDeliveryReceipt) -> GuardianOutboxEntry {
        GuardianOutboxEntry(
            operationID: operationID,
            messageID: messageID,
            targetThreadID: targetThreadID,
            sealedPayload: sealedPayload,
            state: .accepted,
            attemptCount: attemptCount,
            createdAt: createdAt,
            updatedAt: receipt.acceptedAt,
            receipt: receipt
        )
    }

    func acknowledging(at date: Date) -> GuardianOutboxEntry {
        GuardianOutboxEntry(
            operationID: operationID,
            messageID: messageID,
            targetThreadID: targetThreadID,
            sealedPayload: Data(),
            state: .acknowledged,
            attemptCount: attemptCount,
            createdAt: createdAt,
            updatedAt: date,
            receipt: receipt
        )
    }
}
