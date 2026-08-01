import Foundation
import GRDB
import GuardianCore
import Testing

private let durableRemoteNow = Date(timeIntervalSince1970: 2_000)
private let durableRemoteDeviceID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!

@Test func pairingNonceIsOneTimeAndDeviceTrustSurvivesReopen() throws {
    let databaseURL = try remoteDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let challenge = durablePairingChallenge()
    let device = durableRemoteDevice()

    try journal.issuePairingChallenge(challenge, issuedAt: durableRemoteNow)
    try journal.pairRemoteDevice(
        device,
        challenge: challenge,
        at: durableRemoteNow.addingTimeInterval(1)
    )

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.remoteDevice(id: device.id) == device)
    #expect(throws: GuardianJournalError.pairingChallengeConsumed) {
        try reopened.pairRemoteDevice(
            device,
            challenge: challenge,
            at: durableRemoteNow.addingTimeInterval(2)
        )
    }
}

@Test func remoteAcceptanceAndReceiptAreExactlyOnceAcrossReopen() throws {
    let databaseURL = try remoteDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try pairedRemoteJournal(databaseURL: databaseURL)
    let command = durableRemoteCommand()

    let first = try journal.reconcileRemoteCommand(
        command,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 12,
        now: durableRemoteNow.addingTimeInterval(2)
    )
    guard case let .accepted(receipt) = first else {
        Issue.record("Expected durable acceptance")
        return
    }

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.reconcileRemoteCommand(
        command,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 99,
        now: durableRemoteNow.addingTimeInterval(3)
    ) == .duplicate(receipt))
    #expect(try reopened.remoteDevice(id: durableRemoteDeviceID)?.lastAcceptedSequence == 1)
    #expect(try reopened.remoteAuditEvents(limit: 20).filter {
        $0.kind == .commandAccepted && $0.commandID == command.commandID
    }.count == 1)
}

@Test func sequenceGapDoesNotConsumeNonceAndChangedCommandIDConflicts() throws {
    let databaseURL = try remoteDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try pairedRemoteJournal(databaseURL: databaseURL)
    let gap = durableRemoteCommand(sequence: 2)

    #expect(try journal.reconcileRemoteCommand(
        gap,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 12,
        now: durableRemoteNow.addingTimeInterval(2)
    ) == .snapshotRequired(.sequenceGap(expected: 1, received: 2)))

    let corrected = durableRemoteCommand(sequence: 1)
    let accepted = try journal.reconcileRemoteCommand(
        corrected,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 12,
        now: durableRemoteNow.addingTimeInterval(3)
    )
    guard case .accepted = accepted else {
        Issue.record("Gap must not consume the nonce")
        return
    }

    let conflict = durableRemoteCommand(
        sequence: 1,
        payloadDigest: Data(repeating: 0xBB, count: 32)
    )
    #expect(try journal.reconcileRemoteCommand(
        conflict,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 12,
        now: durableRemoteNow.addingTimeInterval(4)
    ) == .rejected(.commandIDConflict))
}

@Test func durableRevocationRejectsCommandsAndRemoteForce() throws {
    let databaseURL = try remoteDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try pairedRemoteJournal(databaseURL: databaseURL)
    let forced = durableRemoteCommand(force: true)

    #expect(try journal.reconcileRemoteCommand(
        forced,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 12,
        now: durableRemoteNow.addingTimeInterval(2)
    ) == .rejected(.remoteForceForbidden))

    let revoked = try journal.revokeRemoteDevice(
        id: durableRemoteDeviceID,
        expectedRevocationEpoch: 0,
        at: durableRemoteNow.addingTimeInterval(3)
    )
    #expect(revoked.status == .revoked)
    #expect(revoked.revocationEpoch == 1)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.reconcileRemoteCommand(
        durableRemoteCommand(revocationEpoch: 1),
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 12,
        now: durableRemoteNow.addingTimeInterval(4)
    ) == .rejected(.deviceRevoked))
}

@Test func remoteJournalPersistsOnlyReplayNonceHash() throws {
    let databaseURL = try remoteDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try pairedRemoteJournal(databaseURL: databaseURL)
    let command = durableRemoteCommand()
    _ = try journal.reconcileRemoteCommand(
        command,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 12,
        now: durableRemoteNow.addingTimeInterval(2)
    )

    let database = try DatabaseQueue(path: databaseURL.path)
    let storedJSON: Data = try database.read { database in
        let value = try Data.fetchOne(
            database,
            sql: "SELECT command_json FROM guardian_remote_commands WHERE command_id = ?",
            arguments: [command.commandID.uuidString]
        )
        return try #require(value)
    }
    let storedText = String(decoding: storedJSON, as: UTF8.self)
    #expect(!storedText.localizedCaseInsensitiveContains(command.nonce.uuidString))
}

private func pairedRemoteJournal(databaseURL: URL) throws -> GuardianJournal {
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let challenge = durablePairingChallenge()
    try journal.issuePairingChallenge(challenge, issuedAt: durableRemoteNow)
    try journal.pairRemoteDevice(
        durableRemoteDevice(),
        challenge: challenge,
        at: durableRemoteNow.addingTimeInterval(1)
    )
    return journal
}

private func durablePairingChallenge() -> GuardianPairingChallenge {
    GuardianPairingChallenge(
        nonce: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
        guardianIdentityHash: Data(repeating: 0x55, count: 32),
        expiresAt: durableRemoteNow.addingTimeInterval(60),
        consumedAt: nil
    )
}

private func durableRemoteDevice() -> GuardianRemoteDevice {
    GuardianRemoteDevice(
        id: durableRemoteDeviceID,
        publicKey: Data(repeating: 0x66, count: 32),
        capabilities: [.observe, .prompt, .policyRecovery],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: durableRemoteNow.addingTimeInterval(1),
        lastSeenAt: nil
    )
}

private func durableRemoteCommand(
    sequence: UInt64 = 1,
    revocationEpoch: UInt64 = 0,
    force: Bool = false,
    payloadDigest: Data = Data(repeating: 0xAA, count: 32)
) -> GuardianRemoteCommand {
    GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
        deviceID: durableRemoteDeviceID,
        expectedGeneration: 12,
        sequence: sequence,
        nonce: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
        issuedAt: durableRemoteNow.addingTimeInterval(1),
        deadline: durableRemoteNow.addingTimeInterval(30),
        revocationEpoch: revocationEpoch,
        targetThreadID: "thread-remote",
        action: .prompt,
        force: force,
        payloadDigest: payloadDigest
    )
}

private func remoteDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-journal-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
