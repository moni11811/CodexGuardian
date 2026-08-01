import Foundation
import Testing
@testable import GuardianCore

@Test func restartIssueIsDurableAndPIDReuseIsFenced() throws {
    let databaseURL = try restartFenceDatabaseURL()
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
        duration: 30
    )
    try journal.transition(
        operationID: operation.id,
        expectedPhase: .prepared,
        to: .gated,
        lease: lease,
        at: Date(timeIntervalSince1970: 101)
    )
    let original = GuardianDesktopProcessIdentity(
        bundleIdentifier: "com.openai.codex",
        bundleURLPath: "/Applications/ChatGPT.app",
        signingIdentifier: "com.openai.codex",
        teamIdentifier: "OPENAI",
        processID: 123,
        processStartIdentity: 4_567,
        serverGeneration: 7
    )
    try journal.storeRestartFence(
        operationID: operation.id,
        identity: original,
        lease: lease,
        at: Date(timeIntervalSince1970: 102)
    )

    #expect(try journal.issueRestart(
        operationID: operation.id,
        observedIdentity: original,
        lease: lease,
        at: Date(timeIntervalSince1970: 103)
    ) == .newlyIssued)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    let reusedPID = GuardianDesktopProcessIdentity(
        bundleIdentifier: original.bundleIdentifier,
        bundleURLPath: original.bundleURLPath,
        signingIdentifier: original.signingIdentifier,
        teamIdentifier: original.teamIdentifier,
        processID: original.processID,
        processStartIdentity: original.processStartIdentity + 1,
        serverGeneration: original.serverGeneration + 1
    )
    #expect(throws: GuardianJournalError.self) {
        try reopened.issueRestart(
            operationID: operation.id,
            observedIdentity: reusedPID,
            lease: lease,
            at: Date(timeIntervalSince1970: 104)
        )
    }
    #expect(try reopened.operation(id: operation.id)?.phase == .restartIssued)
    #expect(try reopened.issueRestart(
        operationID: operation.id,
        observedIdentity: original,
        lease: lease,
        at: Date(timeIntervalSince1970: 104)
    ) == .resumePreviouslyIssued)
}

@Test func corruptRestartFenceIntegerWidthsFailClosedWithoutTrapping() throws {
    #expect(throws: GuardianJournalError.corruptStoredOperation) {
        try GuardianRestartFenceIntegerCodec.decodeProcessID(Int64(Int32.max) + 1)
    }
    #expect(throws: GuardianJournalError.corruptStoredOperation) {
        try GuardianRestartFenceIntegerCodec.decodeProcessID(0)
    }
    #expect(throws: GuardianJournalError.corruptStoredOperation) {
        try GuardianRestartFenceIntegerCodec.decodeProcessStartIdentity(-1)
    }
    #expect(throws: GuardianJournalError.corruptStoredOperation) {
        try GuardianRestartFenceIntegerCodec.encodeProcessStartIdentity(UInt64.max)
    }
    let malformed = GuardianDesktopProcessIdentity(
        bundleIdentifier: "",
        bundleURLPath: "",
        signingIdentifier: "",
        teamIdentifier: nil,
        processID: 0,
        processStartIdentity: 0,
        serverGeneration: -1
    )
    #expect(throws: GuardianJournalError.corruptStoredOperation) {
        try GuardianRestartFenceIntegerCodec.validate(malformed)
    }
}

private func restartFenceDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-restart-fence-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
