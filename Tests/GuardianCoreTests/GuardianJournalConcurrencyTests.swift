import Foundation
import Testing
@testable import GuardianCore

@Test func concurrentDuplicateCallersShareOneOperation() async throws {
    let databaseURL = try concurrentJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journals = try (0..<12).map { _ in try GuardianJournal(databaseURL: databaseURL) }
    let operations = journals.indices.map { index in
        GuardianOperation(
            id: UUID(),
            kind: .nativeRecovery,
            originThreadID: "thread-1",
            originTokenHash: "one-origin-token",
            phase: .prepared,
            createdAt: Date(timeIntervalSince1970: 100 + Double(index)),
            updatedAt: Date(timeIntervalSince1970: 100 + Double(index))
        )
    }

    let operationIDs = try await withThrowingTaskGroup(of: UUID.self) { group in
        for index in journals.indices {
            group.addTask {
                try journals[index].createOrGet(operations[index]).id
            }
        }
        var ids: [UUID] = []
        for try await id in group { ids.append(id) }
        return ids
    }

    #expect(Set(operationIDs).count == 1)
    let storedID = try #require(operationIDs.first)
    #expect(try GuardianJournal(databaseURL: databaseURL).events(operationID: storedID).count == 1)
}

@Test func concurrentIdempotentTransitionsAppendOneEvent() async throws {
    let databaseURL = try concurrentJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: "one-origin-token",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    try GuardianJournal(databaseURL: databaseURL).create(operation)
    let journals = try (0..<12).map { _ in try GuardianJournal(databaseURL: databaseURL) }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for journal in journals {
            group.addTask {
                try journal.transition(
                    operationID: operation.id,
                    to: .targetLoaded,
                    at: Date(timeIntervalSince1970: 101)
                )
            }
        }
        try await group.waitForAll()
    }

    #expect(
        try GuardianJournal(databaseURL: databaseURL)
            .events(operationID: operation.id).map(\.phase)
            == [.prepared, .targetLoaded]
    )
}

@Test func leaseRenewalAndReleasePreserveGenerationFencing() throws {
    let databaseURL = try concurrentJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let owner = UUID()
    let original = try journal.acquireLease(
        resource: "desktop-restart",
        ownerID: owner,
        now: Date(timeIntervalSince1970: 100),
        duration: 10
    )

    let renewed = try journal.renewLease(
        original,
        now: Date(timeIntervalSince1970: 105),
        duration: 30
    )
    #expect(renewed.ownerID == original.ownerID)
    #expect(renewed.generation == original.generation + 1)
    #expect(renewed.expiresAt == Date(timeIntervalSince1970: 135))
    #expect(throws: GuardianJournalError.staleLease("desktop-restart")) {
        try journal.releaseLease(original, at: Date(timeIntervalSince1970: 106))
    }

    try journal.releaseLease(renewed, at: Date(timeIntervalSince1970: 106))
    let replacement = try journal.acquireLease(
        resource: "desktop-restart",
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 106),
        duration: 10
    )
    #expect(replacement.generation == renewed.generation + 1)
}

private func concurrentJournalDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-journal-concurrency-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
