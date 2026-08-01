import Foundation
import GuardianCore
import Testing

@Test func taskSnapshotsPersistMonotonicallyAcrossReopen() throws {
    let databaseURL = try projectionDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let first = GuardianStoredTaskSnapshot(
        threadID: "thread-1",
        state: .running,
        source: .appServerSnapshot,
        serverGeneration: 4,
        eventSequence: 10,
        confidence: 1,
        observedAt: Date(timeIntervalSince1970: 100),
        expiresAt: Date(timeIntervalSince1970: 130),
        inventoryCompleteness: .complete
    )
    try journal.storeTaskSnapshot(first)

    let stale = GuardianStoredTaskSnapshot(
        threadID: first.threadID,
        state: .idle,
        source: .appServerEvent,
        serverGeneration: 4,
        eventSequence: 9,
        confidence: 1,
        observedAt: Date(timeIntervalSince1970: 101),
        expiresAt: Date(timeIntervalSince1970: 131),
        inventoryCompleteness: .complete
    )
    #expect(throws: GuardianJournalError.staleTaskSnapshot("thread-1")) {
        try journal.storeTaskSnapshot(stale)
    }

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.taskSnapshots() == [first])
}

@Test func clientReconnectCursorUsesGenerationAndSequenceCAS() throws {
    let databaseURL = try projectionDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let clientID = UUID()
    let first = GuardianStoredClientSession(
        clientID: clientID,
        role: .macUI,
        generation: 2,
        lastAcknowledgedSequence: 7,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    try journal.storeClientSession(first, expectedCursor: nil)

    let next = GuardianStoredClientSession(
        clientID: clientID,
        role: .macUI,
        generation: 2,
        lastAcknowledgedSequence: 8,
        updatedAt: Date(timeIntervalSince1970: 101)
    )
    #expect(throws: GuardianJournalError.staleClientSession(clientID)) {
        try journal.storeClientSession(
            next,
            expectedCursor: GuardianIPCEventCursor(generation: 2, lastSequence: 6)
        )
    }
    try journal.storeClientSession(
        next,
        expectedCursor: GuardianIPCEventCursor(generation: 2, lastSequence: 7)
    )
    #expect(try journal.clientSession(clientID: clientID) == next)
}

@Test func repairIncidentHistoryPersistsSanitizedCorrectionEvidence() throws {
    let databaseURL = try projectionDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let incident = GuardianStoredIncident(
        id: UUID(),
        operationID: UUID(),
        family: .mcpHost,
        nature: .deterministic,
        symptomCode: "mcp.registration-missing",
        changedVariable: "reload-mcp-host",
        evidenceID: "probe:mcp-list",
        result: .succeeded,
        occurredAt: Date(timeIntervalSince1970: 100)
    )
    try journal.recordIncident(incident)
    try journal.recordIncident(incident)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.incidents(limit: 10) == [incident])
}

private func projectionDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-projections-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
