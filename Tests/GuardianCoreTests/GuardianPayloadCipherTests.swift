import Foundation
import Testing
@testable import GuardianCore

@Test func envelopeCipherBindsPayloadToOperationAndParentKey() throws {
    let operationID = UUID()
    let plaintext = Data("private continuation prompt".utf8)
    let cipher = try GuardianPayloadCipher(parentKeyData: Data(repeating: 0x11, count: 32))
    let sealed = try cipher.seal(plaintext, for: operationID)

    #expect(sealed.range(of: plaintext) == nil)
    #expect(try cipher.open(sealed, for: operationID) == plaintext)
    #expect(throws: Error.self) {
        try cipher.open(sealed, for: UUID())
    }
    let wrongParent = try GuardianPayloadCipher(parentKeyData: Data(repeating: 0x22, count: 32))
    #expect(throws: Error.self) {
        try wrongParent.open(sealed, for: operationID)
    }
}

@Test func acknowledgementPurgesEncryptedPayloadButKeepsReceiptAudit() throws {
    let databaseURL = try payloadJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: UUID().uuidString,
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.create(operation)
    try journal.transition(
        operationID: operation.id,
        to: .targetLoaded,
        at: Date(timeIntervalSince1970: 101)
    )
    let cipher = try GuardianPayloadCipher(parentKeyData: Data(repeating: 0x11, count: 32))
    let entry = GuardianOutboxEntry(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: operation.originThreadID,
        sealedPayload: try cipher.seal(Data("continue".utf8), for: operation.id),
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
    let receipt = GuardianDeliveryReceipt(
        operationID: operation.id,
        messageID: operation.id,
        targetThreadID: operation.originThreadID,
        messageItemID: "item-1",
        turnID: "turn-1",
        acceptedAt: Date(timeIntervalSince1970: 104)
    )
    try journal.recordDeliveryReceipt(receipt)

    try journal.acknowledgeOperation(
        operationID: operation.id,
        at: Date(timeIntervalSince1970: 105)
    )

    let stored = try #require(journal.outboxEntries(operationID: operation.id).first)
    #expect(stored.state == .acknowledged)
    #expect(stored.sealedPayload.isEmpty)
    #expect(stored.receipt == receipt)
    #expect(try journal.operation(id: operation.id)?.phase == .acknowledged)
}

private func payloadJournalDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-payload-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
