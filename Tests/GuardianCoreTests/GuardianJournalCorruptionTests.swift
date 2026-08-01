import Foundation
import GRDB
import Testing
@testable import GuardianCore

@Suite(.serialized)
struct GuardianJournalCorruptionTests {
    @Test func corruptOperationIsQuarantinedWithoutHidingHealthyRows() throws {
        let fixture = try Fixture()
        let healthy = try fixture.createOperation(thread: "healthy-operation")
        let corrupt = try fixture.createOperation(thread: "corrupt-operation")
        try fixture.mutate(
            sql: "UPDATE guardian_operations SET kind = 'invalid-kind' WHERE id = ?",
            arguments: [corrupt.id.uuidString]
        )

        #expect(throws: GuardianJournalError.corruptStoredOperation) {
            _ = try fixture.journal.operations()
        }
        let scan = try fixture.journal.scanOperations()
        #expect(scan.items.map(\.id) == [healthy.id])
        #expect(scan.quarantined == [
            GuardianQuarantinedRow(
                table: "guardian_operations",
                primaryKey: corrupt.id.uuidString,
                reason: .invalidRecord
            ),
        ])
    }

    @Test func corruptPendingOutboxDoesNotBlockHealthyDeliveryScan() throws {
        let fixture = try Fixture()
        let healthy = try fixture.prepareOutbox(thread: "healthy-outbox")
        let corrupt = try fixture.prepareOutbox(thread: "corrupt-outbox")
        try fixture.mutate(
            sql: "UPDATE guardian_outbox SET target_thread_id = '' WHERE message_id = ?",
            arguments: [corrupt.messageID.uuidString]
        )

        #expect(throws: GuardianJournalError.corruptStoredOperation) {
            _ = try fixture.journal.deliverableOutboxEntries()
        }
        let scan = try fixture.journal.scanDeliverableOutboxEntries()
        #expect(scan.items == [healthy])
        #expect(scan.quarantined == [
            GuardianQuarantinedRow(
                table: "guardian_outbox",
                primaryKey: corrupt.messageID.uuidString,
                reason: .invalidRecord
            ),
        ])
    }

    @Test func storageOpenFailureHasStableFailClosedClassification() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "guardian-storage-failure-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "not-a-directory")
        try Data("blocker".utf8).write(to: blocker)

        #expect(throws: GuardianJournalError.storageUnavailable) {
            _ = try GuardianJournal(databaseURL: blocker.appending(path: "guardian.sqlite"))
        }
    }

    private struct Fixture {
        let databaseURL: URL
        let journal: GuardianJournal
        let now = Date(timeIntervalSince1970: 70_000)

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "guardian-corruption-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            databaseURL = directory.appending(path: "guardian.sqlite")
            journal = try GuardianJournal(databaseURL: databaseURL)
        }

        func createOperation(thread: String) throws -> GuardianOperation {
            let operation = GuardianOperation(
                id: UUID(),
                kind: .nativeRecovery,
                originThreadID: thread,
                originTokenHash: UUID().uuidString,
                phase: .prepared,
                createdAt: now,
                updatedAt: now
            )
            _ = try journal.create(operation)
            return operation
        }

        func prepareOutbox(thread: String) throws -> GuardianOutboxEntry {
            let operation = try createOperation(thread: thread)
            _ = try journal.transition(
                operationID: operation.id,
                to: .targetLoaded,
                at: now.addingTimeInterval(1)
            )
            let entry = GuardianOutboxEntry(
                operationID: operation.id,
                messageID: operation.id,
                targetThreadID: thread,
                sealedPayload: Data("ciphertext-\(thread)".utf8),
                state: .pending,
                attemptCount: 0,
                createdAt: now.addingTimeInterval(2),
                updatedAt: now.addingTimeInterval(2),
                receipt: nil
            )
            try journal.enqueueContinuation(entry)
            return entry
        }

        func mutate(sql: String, arguments: StatementArguments) throws {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { database in
                try database.execute(sql: sql, arguments: arguments)
            }
        }
    }
}
