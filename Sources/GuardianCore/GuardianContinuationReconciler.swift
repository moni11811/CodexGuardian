import Foundation

public enum GuardianContinuationObservation: Equatable, Sendable {
    case acceptedMessage(
        threadID: String,
        clientMessageID: UUID,
        messageItemID: String,
        observedAt: Date
    )
    case turnStarted(
        threadID: String,
        clientMessageID: UUID,
        messageItemID: String,
        turnID: String,
        observedAt: Date
    )
    case assistantProgress(threadID: String, turnID: String, observedAt: Date)
    case toolProgress(threadID: String, turnID: String, observedAt: Date)
    case waitingUser(threadID: String, turnID: String, observedAt: Date)
    case terminal(threadID: String, turnID: String, observedAt: Date)
}

public struct GuardianContinuationHistory: Equatable, Sendable {
    public let serverGeneration: Int64
    public let isComplete: Bool
    public let barrierIsClosed: Bool
    public let observations: [GuardianContinuationObservation]

    public init(
        serverGeneration: Int64,
        isComplete: Bool,
        barrierIsClosed: Bool,
        observations: [GuardianContinuationObservation]
    ) {
        self.serverGeneration = serverGeneration
        self.isComplete = isComplete
        self.barrierIsClosed = barrierIsClosed
        self.observations = observations
    }
}

public enum GuardianContinuationOutcome: String, Codable, Equatable, Sendable {
    case working
    case waitingUser
    case finished
    case unknown
}

public enum GuardianContinuationWaitReason: Equatable, Sendable {
    case historyIncomplete
    case snapshotBarrierOpen
    case acceptedMessageWithoutLinkedTurn
}

public enum GuardianContinuationConflict: Equatable, Sendable {
    case invalidOutboxIdentity
    case matchingMessageInWrongThread
    case duplicateAcceptedMessage
    case conflictingTurn
}

public enum GuardianContinuationReconciliation: Equatable, Sendable {
    case sendPermitted
    case waiting(GuardianContinuationWaitReason)
    case accepted(GuardianDeliveryReceipt, outcome: GuardianContinuationOutcome)
    case conflict(GuardianContinuationConflict)
}

public struct GuardianContinuationReconciler: Sendable {
    public init() {}

    public func reconcile(
        entry: GuardianOutboxEntry,
        history: GuardianContinuationHistory
    ) -> GuardianContinuationReconciliation {
        guard entry.operationID == entry.messageID,
              !entry.targetThreadID.isEmpty else {
            return .conflict(.invalidOutboxIdentity)
        }

        var exactMessages: [(itemID: String, observedAt: Date)] = []
        for observation in history.observations {
            switch observation {
            case let .acceptedMessage(threadID, clientMessageID, messageItemID, observedAt):
                guard clientMessageID == entry.messageID else { continue }
                guard threadID == entry.targetThreadID else {
                    return .conflict(.matchingMessageInWrongThread)
                }
                exactMessages.append((messageItemID, observedAt))
            case let .turnStarted(threadID, clientMessageID, _, _, _):
                if clientMessageID == entry.messageID, threadID != entry.targetThreadID {
                    return .conflict(.matchingMessageInWrongThread)
                }
            case .assistantProgress, .toolProgress, .waitingUser, .terminal:
                continue
            }
        }

        let messageIDs = Set(exactMessages.map(\.itemID))
        guard messageIDs.count <= 1 else {
            return .conflict(.duplicateAcceptedMessage)
        }
        guard let message = exactMessages.first else {
            guard history.isComplete else { return .waiting(.historyIncomplete) }
            guard history.barrierIsClosed else { return .waiting(.snapshotBarrierOpen) }
            return .sendPermitted
        }
        guard !message.itemID.isEmpty else {
            return .conflict(.invalidOutboxIdentity)
        }

        let linkedTurns = history.observations.compactMap { observation -> (String, Date)? in
            guard case let .turnStarted(
                threadID,
                clientMessageID,
                messageItemID,
                turnID,
                observedAt
            ) = observation,
            threadID == entry.targetThreadID,
            clientMessageID == entry.messageID,
            messageItemID == message.itemID else { return nil }
            return (turnID, observedAt)
        }
        guard !linkedTurns.isEmpty else {
            return .waiting(.acceptedMessageWithoutLinkedTurn)
        }
        let turnIDs = Set(linkedTurns.map(\.0))
        guard turnIDs.count == 1,
              let turnID = linkedTurns.first?.0,
              !turnID.isEmpty else {
            return .conflict(.conflictingTurn)
        }
        let acceptedAt = linkedTurns.map(\.1).max() ?? message.observedAt
        let receipt = GuardianDeliveryReceipt(
            operationID: entry.operationID,
            messageID: entry.messageID,
            targetThreadID: entry.targetThreadID,
            messageItemID: message.itemID,
            turnID: turnID,
            acceptedAt: acceptedAt
        )
        return .accepted(receipt, outcome: outcome(
            threadID: entry.targetThreadID,
            turnID: turnID,
            observations: history.observations
        ))
    }

    private func outcome(
        threadID: String,
        turnID: String,
        observations: [GuardianContinuationObservation]
    ) -> GuardianContinuationOutcome {
        for observation in observations {
            switch observation {
            case let .waitingUser(observedThread, observedTurn, _)
                where observedThread == threadID && observedTurn == turnID:
                return .waitingUser
            case let .terminal(observedThread, observedTurn, _)
                where observedThread == threadID && observedTurn == turnID:
                return .finished
            default:
                continue
            }
        }
        return .working
    }
}
