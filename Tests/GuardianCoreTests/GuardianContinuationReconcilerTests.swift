import Foundation
import Testing
@testable import GuardianCore

@Test func exactMessageAndTurnProduceReceiptWithoutWaitingForProgress() throws {
    let entry = continuationEntry(state: .awaitingReconciliation, attemptCount: 1)
    let history = GuardianContinuationHistory(
        serverGeneration: 7,
        isComplete: true,
        barrierIsClosed: true,
        observations: [
            .acceptedMessage(
                threadID: entry.targetThreadID,
                clientMessageID: entry.messageID,
                messageItemID: "item-1",
                observedAt: Date(timeIntervalSince1970: 104)
            ),
            .turnStarted(
                threadID: entry.targetThreadID,
                clientMessageID: entry.messageID,
                messageItemID: "item-1",
                turnID: "turn-1",
                observedAt: Date(timeIntervalSince1970: 105)
            ),
        ]
    )

    #expect(GuardianContinuationReconciler().reconcile(entry: entry, history: history)
        == .accepted(GuardianDeliveryReceipt(
            operationID: entry.operationID,
            messageID: entry.messageID,
            targetThreadID: entry.targetThreadID,
            messageItemID: "item-1",
            turnID: "turn-1",
            acceptedAt: Date(timeIntervalSince1970: 105)
        ), outcome: .working))
}

@Test func wrongThreadDuplicateOrUnlinkedTurnFailsClosed() {
    let entry = continuationEntry(state: .awaitingReconciliation, attemptCount: 1)
    let wrongThread = GuardianContinuationHistory(
        serverGeneration: 7,
        isComplete: true,
        barrierIsClosed: true,
        observations: [
            .acceptedMessage(
                threadID: "other-thread",
                clientMessageID: entry.messageID,
                messageItemID: "item-1",
                observedAt: Date()
            ),
        ]
    )
    #expect(GuardianContinuationReconciler().reconcile(entry: entry, history: wrongThread)
        == .conflict(.matchingMessageInWrongThread))

    let unlinked = GuardianContinuationHistory(
        serverGeneration: 7,
        isComplete: true,
        barrierIsClosed: true,
        observations: [
            .acceptedMessage(
                threadID: entry.targetThreadID,
                clientMessageID: entry.messageID,
                messageItemID: "item-1",
                observedAt: Date()
            ),
            .turnStarted(
                threadID: entry.targetThreadID,
                clientMessageID: entry.messageID,
                messageItemID: "different-item",
                turnID: "turn-1",
                observedAt: Date()
            ),
        ]
    )
    #expect(GuardianContinuationReconciler().reconcile(entry: entry, history: unlinked)
        == .waiting(.acceptedMessageWithoutLinkedTurn))
}

@Test func ambiguousAttemptMayResendOnlyAfterCompleteClosedBarrierFindsNothing() {
    let entry = continuationEntry(state: .awaitingReconciliation, attemptCount: 1)
    let incomplete = GuardianContinuationHistory(
        serverGeneration: 7,
        isComplete: false,
        barrierIsClosed: false,
        observations: []
    )
    #expect(GuardianContinuationReconciler().reconcile(entry: entry, history: incomplete)
        == .waiting(.historyIncomplete))

    let openBarrier = GuardianContinuationHistory(
        serverGeneration: 7,
        isComplete: true,
        barrierIsClosed: false,
        observations: []
    )
    #expect(GuardianContinuationReconciler().reconcile(entry: entry, history: openBarrier)
        == .waiting(.snapshotBarrierOpen))

    let closed = GuardianContinuationHistory(
        serverGeneration: 7,
        isComplete: true,
        barrierIsClosed: true,
        observations: []
    )
    #expect(GuardianContinuationReconciler().reconcile(entry: entry, history: closed)
        == .sendPermitted)
}

@Test func tenThousandWrongIdentitiesNeverAccept() {
    let entry = continuationEntry(state: .awaitingReconciliation, attemptCount: 1)
    let reconciler = GuardianContinuationReconciler()
    for index in 0..<10_000 {
        let wrongID = UUID(uuidString: String(
            format: "00000000-0000-0000-0001-%012d",
            index
        ))!
        let history = GuardianContinuationHistory(
            serverGeneration: 7,
            isComplete: true,
            barrierIsClosed: true,
            observations: [
                .acceptedMessage(
                    threadID: entry.targetThreadID,
                    clientMessageID: wrongID,
                    messageItemID: "item-\(index)",
                    observedAt: Date(timeIntervalSince1970: Double(index))
                ),
                .turnStarted(
                    threadID: entry.targetThreadID,
                    clientMessageID: wrongID,
                    messageItemID: "item-\(index)",
                    turnID: "turn-\(index)",
                    observedAt: Date(timeIntervalSince1970: Double(index))
                ),
            ]
        )
        #expect(reconciler.reconcile(entry: entry, history: history) != .accepted(
            GuardianDeliveryReceipt(
                operationID: entry.operationID,
                messageID: entry.messageID,
                targetThreadID: entry.targetThreadID,
                messageItemID: "item-\(index)",
                turnID: "turn-\(index)",
                acceptedAt: Date(timeIntervalSince1970: Double(index))
            ),
            outcome: .working
        ))
    }
}

private func continuationEntry(
    state: GuardianOutboxState,
    attemptCount: Int
) -> GuardianOutboxEntry {
    let id = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    return GuardianOutboxEntry(
        operationID: id,
        messageID: id,
        targetThreadID: "target-thread",
        sealedPayload: Data([0x01]),
        state: state,
        attemptCount: attemptCount,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 103),
        receipt: nil
    )
}
