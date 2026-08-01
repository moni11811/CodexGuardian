import Foundation
import Testing
@testable import GuardianCore

@Test func restartBudgetAndCircuitSurviveReopenWithCASFencing() throws {
    let databaseURL = try restartBudgetDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let start = Date(timeIntervalSince1970: 10_000)
    var state = RestartCircuitState.empty
    state = state.recordingDesktopRestart(
        at: start,
        result: .failed,
        configuration: .test
    )
    state = state.recordingDesktopRestart(
        at: start.addingTimeInterval(11),
        result: .failed,
        configuration: .test
    )
    let first = try GuardianJournal(databaseURL: databaseURL).storeRestartCircuit(
        scope: "desktop",
        state: state,
        expectedVersion: nil,
        at: start.addingTimeInterval(11)
    )
    #expect(first.version == 1)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.restartCircuit(scope: "desktop") == first)
    #expect(first.state.isOpen)

    let reset = state.manuallyReset(at: start.addingTimeInterval(12))
    let second = try reopened.storeRestartCircuit(
        scope: "desktop",
        state: reset,
        expectedVersion: first.version,
        at: start.addingTimeInterval(12)
    )
    #expect(second.version == 2)
    #expect(!second.state.isOpen)

    #expect(throws: GuardianJournalError.self) {
        try reopened.storeRestartCircuit(
            scope: "desktop",
            state: state,
            expectedVersion: first.version,
            at: start.addingTimeInterval(13)
        )
    }
    #expect(try reopened.restartCircuit(scope: "desktop") == second)
}

private func restartBudgetDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-budget-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
