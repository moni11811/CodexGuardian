import Foundation
import Testing
@testable import GuardianCore

@Test func continuationQueueIsAtomicDurableAndIdempotent() throws {
    let databaseURL = try outboxDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = try preparedNativeOperation(in: databaseURL)
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.transition(
        operationID: operation.id,
        to: .targetLoaded,
        at: Date(timeIntervalSince1970: 101)
    )
    let entry = GuardianOutboxEntry(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: operation.originThreadID,
        sealedPayload: Data([0x01, 0x02, 0x03]),
        state: .pending,
        attemptCount: 0,
        createdAt: Date(timeIntervalSince1970: 102),
        updatedAt: Date(timeIntervalSince1970: 102),
        receipt: nil
    )

    try journal.enqueueContinuation(entry)
    try journal.enqueueContinuation(entry)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.operation(id: operation.id)?.phase == .continuationSent)
    #expect(try reopened.outboxEntries(operationID: operation.id) == [entry])
    #expect(
        try reopened.events(operationID: operation.id).map(\.phase)
            == [.prepared, .targetLoaded, .continuationSent]
    )
}

@Test func ambiguousSendRequiresReconciliationBeforeResend() throws {
    let databaseURL = try outboxDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = try preparedNativeOperation(in: databaseURL)
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.transition(
        operationID: operation.id,
        to: .targetLoaded,
        at: Date(timeIntervalSince1970: 101)
    )
    let entry = GuardianOutboxEntry(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: operation.originThreadID,
        sealedPayload: Data([0xA5]),
        state: .pending,
        attemptCount: 0,
        createdAt: Date(timeIntervalSince1970: 102),
        updatedAt: Date(timeIntervalSince1970: 102),
        receipt: nil
    )
    try journal.enqueueContinuation(entry)
    try journal.beginOutboxDeliveryAttempt(
        messageID: entry.messageID,
        at: Date(timeIntervalSince1970: 103)
    )

    #expect(try journal.deliverableOutboxEntries().isEmpty)
    #expect(try journal.outboxEntriesNeedingReconciliation().map(\.messageID) == [entry.messageID])

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.deliverableOutboxEntries().isEmpty)
    #expect(try reopened.outboxEntriesNeedingReconciliation().map(\.messageID) == [entry.messageID])
}

@Test func deliveryAttemptIsPersistedBeforeExternalSendCanBegin() throws {
    let databaseURL = try outboxDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = try preparedNativeOperation(in: databaseURL)
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.transition(
        operationID: operation.id,
        to: .targetLoaded,
        at: Date(timeIntervalSince1970: 101)
    )
    let entry = GuardianOutboxEntry(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: operation.originThreadID,
        sealedPayload: Data([0xA5]),
        state: .pending,
        attemptCount: 0,
        createdAt: Date(timeIntervalSince1970: 102),
        updatedAt: Date(timeIntervalSince1970: 102),
        receipt: nil
    )
    try journal.enqueueContinuation(entry)

    let attempt = try journal.beginOutboxDeliveryAttempt(
        messageID: entry.messageID,
        at: Date(timeIntervalSince1970: 103)
    )
    #expect(attempt.state == .awaitingReconciliation)
    #expect(attempt.attemptCount == 1)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.deliverableOutboxEntries().isEmpty)
    #expect(try reopened.outboxEntriesNeedingReconciliation() == [attempt])
}

@Test func deliveryReceiptRequiresExactThreadMessageAndTurn() throws {
    let databaseURL = try outboxDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = try preparedNativeOperation(in: databaseURL)
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.transition(
        operationID: operation.id,
        to: .targetLoaded,
        at: Date(timeIntervalSince1970: 101)
    )
    let entry = GuardianOutboxEntry(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: operation.originThreadID,
        sealedPayload: Data([0xA5]),
        state: .pending,
        attemptCount: 0,
        createdAt: Date(timeIntervalSince1970: 102),
        updatedAt: Date(timeIntervalSince1970: 102),
        receipt: nil
    )
    try journal.enqueueContinuation(entry)
    try journal.beginOutboxDeliveryAttempt(
        messageID: entry.messageID,
        at: Date(timeIntervalSince1970: 103)
    )
    let wrongThread = GuardianDeliveryReceipt(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: "thread-2",
        messageItemID: "item-1",
        turnID: "turn-1",
        acceptedAt: Date(timeIntervalSince1970: 104)
    )
    #expect(throws: GuardianJournalError.self) {
        try journal.recordDeliveryReceipt(wrongThread)
    }
    #expect(try journal.operation(id: operation.id)?.phase == .continuationSent)

    let receipt = GuardianDeliveryReceipt(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: operation.originThreadID,
        messageItemID: "item-1",
        turnID: "turn-1",
        acceptedAt: Date(timeIntervalSince1970: 104)
    )
    try journal.recordDeliveryReceipt(receipt)
    try journal.recordDeliveryReceipt(receipt)
    #expect(try journal.operation(id: operation.id)?.phase == .deliveryReceipt)
    #expect(try journal.outboxEntries(operationID: operation.id).first?.receipt == receipt)

    let conflictingReceipt = GuardianDeliveryReceipt(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: operation.originThreadID,
        messageItemID: "item-1",
        turnID: "turn-2",
        acceptedAt: Date(timeIntervalSince1970: 105)
    )
    #expect(throws: GuardianJournalError.self) {
        try journal.recordDeliveryReceipt(conflictingReceipt)
    }
}

private func preparedNativeOperation(in databaseURL: URL) throws -> GuardianOperation {
    let operation = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: UUID().uuidString,
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    try GuardianJournal(databaseURL: databaseURL).create(operation)
    return operation
}

private func outboxDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-outbox-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
