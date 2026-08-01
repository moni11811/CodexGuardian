import Foundation
import Testing
@testable import GuardianCore

@Test func journalPersistsPreparedOperationAcrossReopen() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: "origin-hash",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )

    let first = try GuardianJournal(databaseURL: databaseURL)
    try first.create(operation)
    #expect(try first.storageJournalMode() == "wal")

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.operation(id: operation.id) == operation)
    #expect(try reopened.events(operationID: operation.id).map(\.phase) == [.prepared])
}

@Test func journalTransitionIsIdempotentAndRejectsUnsafeSkip() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: "origin-hash",
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
    try journal.transition(
        operationID: operation.id,
        to: .targetLoaded,
        at: Date(timeIntervalSince1970: 101)
    )

    #expect(try journal.events(operationID: operation.id).map(\.phase) == [.prepared, .targetLoaded])
    #expect(throws: GuardianJournalError.self) {
        try journal.transition(
            operationID: operation.id,
            to: .controlReady,
            at: Date(timeIntervalSince1970: 102)
        )
    }
}

@Test func hardRestartCannotSkipGlobalGate() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .hardRestart,
        originThreadID: "thread-1",
        originTokenHash: "origin-hash",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.create(operation)
    let lease = try journal.acquireLease(
        resource: "desktop-restart",
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 100),
        duration: 10
    )

    #expect(throws: GuardianJournalError.self) {
        try journal.transition(
            operationID: operation.id,
            expectedPhase: .prepared,
            to: .targetLoaded,
            lease: lease,
            at: Date(timeIntervalSince1970: 101)
        )
    }
    #expect(try journal.events(operationID: operation.id).map(\.phase) == [.prepared])
}

@Test func nativeRecoveryMayLoadItsVerifiedTargetWithoutRestartStages() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: "origin-hash",
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

    #expect(try journal.events(operationID: operation.id).map(\.phase) == [.prepared, .targetLoaded])
}

@Test func terminalFailureCannotBeRewritten() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: "origin-hash",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.create(operation)
    try journal.transition(
        operationID: operation.id,
        to: .failed,
        at: Date(timeIntervalSince1970: 101)
    )

    #expect(throws: GuardianJournalError.self) {
        try journal.transition(
            operationID: operation.id,
            to: .timedOut,
            at: Date(timeIntervalSince1970: 102)
        )
    }
    #expect(try journal.events(operationID: operation.id).map(\.phase) == [.prepared, .failed])
}

@Test func staleLeaseOwnerCannotAdvanceHardRestart() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .hardRestart,
        originThreadID: "thread-1",
        originTokenHash: "origin-hash",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let firstOwner = UUID()
    let secondOwner = UUID()
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.create(operation)
    let firstLease = try journal.acquireLease(
        resource: "desktop-restart",
        ownerID: firstOwner,
        now: Date(timeIntervalSince1970: 100),
        duration: 10
    )
    try journal.transition(
        operationID: operation.id,
        expectedPhase: .prepared,
        to: .gated,
        lease: firstLease,
        at: Date(timeIntervalSince1970: 101)
    )

    let secondLease = try journal.acquireLease(
        resource: "desktop-restart",
        ownerID: secondOwner,
        now: Date(timeIntervalSince1970: 111),
        duration: 10
    )
    #expect(secondLease.generation > firstLease.generation)
    #expect(throws: GuardianJournalError.self) {
        try journal.transition(
            operationID: operation.id,
            expectedPhase: .gated,
            to: .restartIssued,
            lease: firstLease,
            at: Date(timeIntervalSince1970: 112)
        )
    }
    try journal.transition(
        operationID: operation.id,
        expectedPhase: .gated,
        to: .restartIssued,
        lease: secondLease,
        at: Date(timeIntervalSince1970: 112)
    )
}

@Test func hardRestartTransitionRequiresLease() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .hardRestart,
        originThreadID: "thread-1",
        originTokenHash: "origin-hash",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.create(operation)

    #expect(throws: GuardianJournalError.self) {
        try journal.transition(
            operationID: operation.id,
            to: .gated,
            at: Date(timeIntervalSince1970: 101)
        )
    }
}

@Test func duplicateOriginTokenReturnsOneOperationAndConflictFailsClosed() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let first = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: "same-origin",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let duplicate = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "thread-1",
        originTokenHash: "same-origin",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 101),
        updatedAt: Date(timeIntervalSince1970: 101)
    )

    let stored = try journal.createOrGet(first)
    let reused = try journal.createOrGet(duplicate)
    #expect(stored.id == first.id)
    #expect(reused.id == first.id)
    #expect(try journal.events(operationID: first.id).count == 1)

    let conflict = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "different-thread",
        originTokenHash: "same-origin",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 102),
        updatedAt: Date(timeIntervalSince1970: 102)
    )
    #expect(throws: GuardianJournalError.self) {
        try journal.createOrGet(conflict)
    }
}

@Test func journalUsesFullDurabilityAndOwnerOnlyStorageFiles() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
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

    #expect(try journal.storageSynchronousMode() == 2)
    for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"] {
        #expect(FileManager.default.fileExists(atPath: path))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }
}

@Test func transitionEventPersistsActorReasonGenerationAndEvidence() throws {
    let databaseURL = try temporaryJournalDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let operation = GuardianOperation(
        id: UUID(),
        kind: .hardRestart,
        originThreadID: "thread-1",
        originTokenHash: UUID().uuidString,
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.create(operation)
    let lease = try journal.acquireLease(
        resource: "desktop-restart",
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 100),
        duration: 10
    )
    let context = GuardianTransitionContext(
        actor: .daemon,
        reason: "complete global inventory is idle",
        serverGeneration: 7,
        evidenceID: "snapshot-42"
    )

    try journal.transition(
        operationID: operation.id,
        expectedPhase: .prepared,
        to: .gated,
        lease: lease,
        context: context,
        at: Date(timeIntervalSince1970: 101)
    )

    let events = try journal.events(operationID: operation.id)
    #expect(events[0].actor == .client)
    #expect(events[0].reason == "operation.created")
    #expect(events[1].actor == context.actor)
    #expect(events[1].reason == context.reason)
    #expect(events[1].serverGeneration == context.serverGeneration)
    #expect(events[1].evidenceID == context.evidenceID)
}

private func temporaryJournalDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-journal-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
