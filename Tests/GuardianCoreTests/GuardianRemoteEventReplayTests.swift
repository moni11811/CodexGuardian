import Foundation
import GuardianCore
import Testing

@Test func daemonEventsReplayDurablyAcrossReconnectAndReopen() throws {
    let directory = try remoteReplayDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "guardian.sqlite")
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let state = try journal.beginDaemonGeneration(at: Date(timeIntervalSince1970: 100))
    let first = try journal.appendDaemonEvent(
        kind: .taskChanged,
        operationID: nil,
        expectedGeneration: state.generation,
        at: Date(timeIntervalSince1970: 101)
    )
    let second = try journal.appendDaemonEvent(
        kind: .daemonGenerationChanged,
        operationID: nil,
        expectedGeneration: state.generation,
        at: Date(timeIntervalSince1970: 102)
    )
    let reopened = try GuardianJournal(databaseURL: databaseURL)

    #expect(try reopened.replayDaemonEvents(
        after: GuardianIPCEventCursor(generation: state.generation, lastSequence: 0),
        limit: 20
    ) == .events(
        [first, second],
        nextCursor: GuardianIPCEventCursor(
            generation: state.generation,
            lastSequence: second.sequence
        )
    ))
}

@Test func reconnectGenerationChangeOrDurableGapRequiresSnapshot() throws {
    let directory = try remoteReplayDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let state = try journal.beginDaemonGeneration(at: Date(timeIntervalSince1970: 100))

    #expect(try journal.replayDaemonEvents(
        after: GuardianIPCEventCursor(generation: state.generation + 1, lastSequence: 0),
        limit: 20
    ) == .snapshotRequired(.generationChanged(
        expected: state.generation + 1,
        received: state.generation
    )))

    _ = try journal.nextDaemonEventSequence(
        expectedGeneration: state.generation,
        at: Date(timeIntervalSince1970: 101)
    )
    let received = try journal.appendDaemonEvent(
        kind: .taskChanged,
        operationID: nil,
        expectedGeneration: state.generation,
        at: Date(timeIntervalSince1970: 102)
    )
    #expect(try journal.replayDaemonEvents(
        after: GuardianIPCEventCursor(generation: state.generation, lastSequence: 0),
        limit: 20
    ) == .snapshotRequired(.sequenceGap(expected: 1, received: received.sequence)))
}

private func remoteReplayDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-replay-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
