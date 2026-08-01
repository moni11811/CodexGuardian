import Foundation
import Testing
@testable import GuardianCore

@Test func atomicCutoverPreventsMixedLegacyAndDaemonRestartAuthority() throws {
    let databaseURL = try authorityDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try seedAuthorityInventory(journal)
    let legacyPermit = try journal.issueAuthorityPermit(
        owner: .legacy,
        at: Date(timeIntervalSince1970: 100)
    )

    #expect(throws: GuardianAuthorityFenceError.authorityDenied(.daemon)) {
        try journal.issueAuthorityPermit(
            owner: .daemon,
            at: Date(timeIntervalSince1970: 100)
        )
    }

    let lease = try journal.acquireLease(
        resource: GuardianAuthorityFence.cutoverLeaseResource,
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 101),
        duration: 30
    )
    let prepared = try journal.prepareAuthorityCutover(
        proof: GuardianAuthorityCutoverProof(
            desktopControlEvidenceID: "gate0-live-desktop-write",
            observerComparisonEvidenceID: "phase3-shadow-comparison",
            deploymentID: "deployment-v1",
            daemonGeneration: 1
        ),
        lease: lease,
        at: Date(timeIntervalSince1970: 102)
    )
    #expect(prepared.phase == .prepared)
    try journal.validateAuthorityPermit(
        legacyPermit,
        at: Date(timeIntervalSince1970: 102)
    )

    let activated = try journal.activateAuthorityCutover(
        expectedEpoch: prepared.epoch,
        lease: lease,
        at: Date(timeIntervalSince1970: 103)
    )
    #expect(activated.phase == .daemonAuthoritative)

    #expect(throws: GuardianAuthorityFenceError.stalePermit) {
        try journal.validateAuthorityPermit(
            legacyPermit,
            at: Date(timeIntervalSince1970: 103)
        )
    }
    #expect(throws: GuardianAuthorityFenceError.authorityDenied(.legacy)) {
        try journal.issueAuthorityPermit(
            owner: .legacy,
            at: Date(timeIntervalSince1970: 103)
        )
    }
    let daemonPermit = try journal.issueAuthorityPermit(
        owner: .daemon,
        at: Date(timeIntervalSince1970: 103)
    )
    try journal.validateAuthorityPermit(
        daemonPermit,
        at: Date(timeIntervalSince1970: 104)
    )

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.authorityFence() == activated)
    #expect(throws: GuardianAuthorityFenceError.authorityDenied(.legacy)) {
        try reopened.issueAuthorityPermit(
            owner: .legacy,
            at: Date(timeIntervalSince1970: 105)
        )
    }
}

@Test func cutoverFailsClosedWithoutCompleteGateAndComparisonProof() throws {
    let databaseURL = try authorityDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try seedAuthorityInventory(journal)
    let lease = try journal.acquireLease(
        resource: GuardianAuthorityFence.cutoverLeaseResource,
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 100),
        duration: 30
    )

    #expect(throws: GuardianAuthorityFenceError.invalidCutoverProof) {
        try journal.prepareAuthorityCutover(
            proof: GuardianAuthorityCutoverProof(
                desktopControlEvidenceID: "",
                observerComparisonEvidenceID: "phase3-shadow-comparison",
                deploymentID: "deployment-v1",
                daemonGeneration: 1
            ),
            lease: lease,
            at: Date(timeIntervalSince1970: 101)
        )
    }
    #expect(try journal.authorityFence().phase == .legacyAuthoritative)
}

@Test func committedCutoverHasOneDurableAuditEventAndIdempotentReplay() throws {
    let databaseURL = try authorityDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try seedAuthorityInventory(journal)
    let lease = try journal.acquireLease(
        resource: GuardianAuthorityFence.cutoverLeaseResource,
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 100),
        duration: 30
    )
    let proof = GuardianAuthorityCutoverProof(
        desktopControlEvidenceID: "gate0-live-desktop-write",
        observerComparisonEvidenceID: "phase3-shadow-comparison",
        deploymentID: "deployment-v1",
        daemonGeneration: 1
    )
    let prepared = try journal.prepareAuthorityCutover(
        proof: proof,
        lease: lease,
        at: Date(timeIntervalSince1970: 101)
    )
    let first = try journal.activateAuthorityCutover(
        expectedEpoch: prepared.epoch,
        lease: lease,
        at: Date(timeIntervalSince1970: 102)
    )
    let replay = try journal.activateAuthorityCutover(
        expectedEpoch: prepared.epoch,
        lease: lease,
        at: Date(timeIntervalSince1970: 103)
    )
    #expect(replay == first)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    let events = try reopened.authorityEvents()
    #expect(events.filter { $0.to == .daemonAuthoritative }.count == 1)
    #expect(events.last?.epoch == first.epoch)
    #expect(events.last?.proof == proof)
}

@Test func cutoverRejectsMissingAuthoritativeInventoryCheckpoint() throws {
    let databaseURL = try authorityDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    _ = try journal.beginDaemonGeneration(at: Date(timeIntervalSince1970: 99))
    let lease = try journal.acquireLease(
        resource: GuardianAuthorityFence.cutoverLeaseResource,
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 100),
        duration: 30
    )

    #expect(throws: GuardianAuthorityFenceError.inventoryNotAuthoritative) {
        try journal.prepareAuthorityCutover(
            proof: GuardianAuthorityCutoverProof(
                desktopControlEvidenceID: "gate0-live-desktop-write",
                observerComparisonEvidenceID: "phase3-shadow-comparison",
                deploymentID: "deployment-v1",
                daemonGeneration: 1
            ),
            lease: lease,
            at: Date(timeIntervalSince1970: 101)
        )
    }
    #expect(try journal.authorityFence().phase == .legacyAuthoritative)
}

@Test func cutoverRejectsUnreconciledLegacyOperation() throws {
    let databaseURL = try authorityDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try seedAuthorityInventory(journal)
    let operation = GuardianOperation(
        id: UUID(),
        kind: .nativeRecovery,
        originThreadID: "legacy-thread",
        originTokenHash: "legacy-origin",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 99),
        updatedAt: Date(timeIntervalSince1970: 99)
    )
    _ = try journal.create(operation)
    let lease = try journal.acquireLease(
        resource: GuardianAuthorityFence.cutoverLeaseResource,
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 100),
        duration: 30
    )

    #expect(throws: GuardianAuthorityFenceError.legacyOperationInFlight(operation.id)) {
        try journal.prepareAuthorityCutover(
            proof: GuardianAuthorityCutoverProof(
                desktopControlEvidenceID: "gate0-live-desktop-write",
                observerComparisonEvidenceID: "phase3-shadow-comparison",
                deploymentID: "deployment-v1",
                daemonGeneration: 1
            ),
            lease: lease,
            at: Date(timeIntervalSince1970: 101)
        )
    }
    #expect(try journal.authorityFence().phase == .legacyAuthoritative)
}

@Test func cutoverRejectsStaleDaemonGenerationProof() throws {
    let databaseURL = try authorityDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try seedAuthorityInventory(journal)
    let current = try journal.beginDaemonGeneration(at: Date(timeIntervalSince1970: 99))
    let lease = try journal.acquireLease(
        resource: GuardianAuthorityFence.cutoverLeaseResource,
        ownerID: UUID(),
        now: Date(timeIntervalSince1970: 100),
        duration: 30
    )

    #expect(throws: GuardianAuthorityFenceError.daemonGenerationMismatch(
        expected: current.generation + 1,
        actual: current.generation
    )) {
        try journal.prepareAuthorityCutover(
            proof: GuardianAuthorityCutoverProof(
                desktopControlEvidenceID: "gate0-live-desktop-write",
                observerComparisonEvidenceID: "phase3-shadow-comparison",
                deploymentID: "deployment-v1",
                daemonGeneration: current.generation + 1
            ),
            lease: lease,
            at: Date(timeIntervalSince1970: 101)
        )
    }
    #expect(try journal.authorityFence().phase == .legacyAuthoritative)
}

private func authorityDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-authority-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}

private func seedAuthorityInventory(_ journal: GuardianJournal) throws {
    _ = try journal.beginDaemonGeneration(at: Date(timeIntervalSince1970: 98))
    try journal.replaceTaskSnapshots(
        [],
        serverGeneration: 7,
        eventSequence: 42,
        capturedAt: Date(timeIntervalSince1970: 99),
        expiresAt: Date(timeIntervalSince1970: 200),
        inventoryCompleteness: .complete
    )
}
