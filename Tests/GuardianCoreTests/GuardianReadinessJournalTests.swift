import Foundation
import Testing
@testable import GuardianCore

@Test func readinessManifestSurvivesReopenAndPreservesExactDegradation() throws {
    let databaseURL = try readinessDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let operation = GuardianOperation(
        id: UUID(),
        kind: .hardRestart,
        originThreadID: "exact-thread",
        originTokenHash: "readiness-origin",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    _ = try journal.create(operation)
    let records = [
        persistedReadiness("desktop.started", requirement: .required, state: .ready),
        persistedReadiness("control.ready", requirement: .required, state: .ready),
        persistedReadiness("schema.ready", requirement: .required, state: .ready),
        persistedReadiness("target.loaded", requirement: .required, state: .ready),
        persistedReadiness("plugin.context-mode", requirement: .optional, state: .failed),
    ]
    try journal.replaceReadinessManifest(operationID: operation.id, records: records)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    let stored = try reopened.readinessManifest(operationID: operation.id)
    #expect(stored == records.sorted { $0.capability < $1.capability })
    #expect(GuardianReadinessPolicy().decision(
        records: stored,
        now: Date(timeIntervalSince1970: 105)
    ) == .ready(degraded: ["plugin.context-mode"]))
}

private func persistedReadiness(
    _ capability: String,
    requirement: GuardianCapabilityRequirement,
    state: GuardianCapabilityState
) -> GuardianCapabilityRecord {
    GuardianCapabilityRecord(
        capability: capability,
        requirement: requirement,
        state: state,
        evidenceID: "evidence-\(capability)",
        observedAt: Date(timeIntervalSince1970: 100),
        deadline: Date(timeIntervalSince1970: 110)
    )
}

private func readinessDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-readiness-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
