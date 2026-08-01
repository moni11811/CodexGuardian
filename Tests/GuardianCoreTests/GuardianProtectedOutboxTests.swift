import Foundation
import Testing
@testable import GuardianCore

@Suite(.serialized)
struct GuardianProtectedOutboxTests {
    @Test func plaintextIsEncryptedBeforeJournalInsertionAndBoundToOperation() async throws {
        let fixture = try Fixture()
        let operation = try fixture.prepareNativeOperation()
        let plaintext = Data("continue exact task without secrets".utf8)

        let stored = try await fixture.outbox.enqueue(
            operationID: operation.id,
            targetThreadID: operation.originThreadID,
            plaintext: plaintext,
            at: fixture.now.addingTimeInterval(3)
        )

        #expect(stored.sealedPayload != plaintext)
        #expect(!stored.sealedPayload.isEmpty)
        #expect(try await fixture.outbox.open(stored) == plaintext)

        let wrongOperation = GuardianOutboxEntry(
            operationID: UUID(),
            messageID: stored.messageID,
            targetThreadID: stored.targetThreadID,
            sealedPayload: stored.sealedPayload,
            state: stored.state,
            attemptCount: stored.attemptCount,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            receipt: stored.receipt
        )
        await #expect(throws: (any Error).self) {
            try await fixture.outbox.open(wrongOperation)
        }
    }

    @Test func acknowledgedEnvelopeCannotRecoverPlaintext() async throws {
        let fixture = try Fixture()
        let operation = try fixture.prepareNativeOperation()
        let entry = try await fixture.outbox.enqueue(
            operationID: operation.id,
            targetThreadID: operation.originThreadID,
            plaintext: Data("one use continuation".utf8),
            at: fixture.now.addingTimeInterval(3)
        )
        _ = try fixture.journal.beginOutboxDeliveryAttempt(
            messageID: entry.messageID,
            at: fixture.now.addingTimeInterval(4)
        )
        try fixture.journal.recordDeliveryReceipt(GuardianDeliveryReceipt(
            operationID: operation.id,
            messageID: entry.messageID,
            targetThreadID: operation.originThreadID,
            messageItemID: "message-item",
            turnID: "turn",
            acceptedAt: fixture.now.addingTimeInterval(5)
        ))
        try fixture.journal.acknowledgeOperation(
            operationID: operation.id,
            at: fixture.now.addingTimeInterval(6)
        )
        let acknowledged = try #require(
            fixture.journal.outboxEntries(operationID: operation.id).first
        )

        #expect(acknowledged.sealedPayload.isEmpty)
        await #expect(throws: (any Error).self) {
            try await fixture.outbox.open(acknowledged)
        }
    }

    private struct Fixture {
        let now = Date(timeIntervalSince1970: 50_000)
        let journal: GuardianJournal
        let outbox: GuardianProtectedOutbox

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "guardian-protected-outbox-\(UUID().uuidString)")
            journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
            let key = Data(repeating: 0x7C, count: 32)
            let manager = GuardianParentKeyManager(
                storage: FixedSecretStorage(key: key),
                generator: { key }
            )
            outbox = GuardianProtectedOutbox(journal: journal, keyManager: manager)
        }

        func prepareNativeOperation() throws -> GuardianOperation {
            let operation = GuardianOperation(
                id: UUID(),
                kind: .nativeRecovery,
                originThreadID: "thread-protected",
                originTokenHash: UUID().uuidString,
                phase: .prepared,
                createdAt: now,
                updatedAt: now
            )
            _ = try journal.create(operation)
            _ = try journal.transition(
                operationID: operation.id,
                to: .targetLoaded,
                at: now.addingTimeInterval(2)
            )
            return operation
        }
    }
}

private struct FixedSecretStorage: GuardianSecretStorage {
    let key: Data

    func read(service: String, account: String) throws -> Data? { key }
    func insert(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}
