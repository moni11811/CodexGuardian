import Foundation
import Testing
@testable import GuardianCore

@Test func daemonGenerationAdvancesAcrossReopenAndSequenceIsCASFenced() throws {
    let databaseURL = try daemonStateDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let firstJournal = try GuardianJournal(databaseURL: databaseURL)
    let first = try firstJournal.beginDaemonGeneration(at: Date(timeIntervalSince1970: 100))
    #expect(first.generation == 1)
    #expect(first.lastSequence == 0)
    let firstEvent = try firstJournal.nextDaemonEventSequence(
        expectedGeneration: first.generation,
        at: Date(timeIntervalSince1970: 101)
    )
    #expect(firstEvent == 1)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    let second = try reopened.beginDaemonGeneration(at: Date(timeIntervalSince1970: 102))
    #expect(second.generation == 2)
    #expect(second.lastSequence == 0)
    #expect(throws: GuardianJournalError.self) {
        try reopened.nextDaemonEventSequence(
            expectedGeneration: first.generation,
            at: Date(timeIntervalSince1970: 103)
        )
    }
    #expect(try reopened.nextDaemonEventSequence(
        expectedGeneration: second.generation,
        at: Date(timeIntervalSince1970: 103)
    ) == 1)
}

private func daemonStateDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-daemon-state-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
