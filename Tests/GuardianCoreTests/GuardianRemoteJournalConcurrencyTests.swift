import Foundation
import GuardianCore
import Testing

private let remoteRaceNow = Date(timeIntervalSince1970: 8_000)
private let remoteRaceDeviceID = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!

@Test func concurrentRemoteDuplicateAcrossJournalHandlesIsExactlyOnce() async throws {
    let databaseURL = try remoteRaceDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let first = try pairedRemoteRaceJournal(databaseURL: databaseURL)
    let second = try GuardianJournal(databaseURL: databaseURL)
    let command = remoteRaceCommand()

    let results = try await withThrowingTaskGroup(
        of: GuardianRemoteReconciliation.self
    ) { group in
        for journal in [first, second] {
            group.addTask {
                await Task.yield()
                return try journal.reconcileRemoteCommand(
                    command,
                    sealedPayload: guardianTestSealedPayload(),
                    currentGeneration: 42,
                    now: remoteRaceNow.addingTimeInterval(2)
                )
            }
        }
        var values: [GuardianRemoteReconciliation] = []
        for try await value in group { values.append(value) }
        return values
    }

    let accepted = results.compactMap { result -> GuardianRemoteReceipt? in
        guard case let .accepted(receipt) = result else { return nil }
        return receipt
    }
    let duplicates = results.compactMap { result -> GuardianRemoteReceipt? in
        guard case let .duplicate(receipt) = result else { return nil }
        return receipt
    }
    #expect(accepted.count == 1)
    #expect(duplicates == accepted)

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    #expect(try reopened.remoteDevice(id: remoteRaceDeviceID)?.lastAcceptedSequence == 1)
    #expect(try reopened.remoteAuditEvents(limit: 20).filter {
        $0.kind == .commandAccepted && $0.commandID == command.commandID
    }.count == 1)
}

@Test func remoteAcceptanceRacingRevocationIsLinearizable() async throws {
    let databaseURL = try remoteRaceDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let commandJournal = try pairedRemoteRaceJournal(databaseURL: databaseURL)
    let revocationJournal = try GuardianJournal(databaseURL: databaseURL)
    let command = remoteRaceCommand()

    let outcomes = try await withThrowingTaskGroup(of: RemoteRaceOutcome.self) { group in
        group.addTask {
            await Task.yield()
            return .command(try commandJournal.reconcileRemoteCommand(
                command,
                sealedPayload: guardianTestSealedPayload(),
                currentGeneration: 42,
                now: remoteRaceNow.addingTimeInterval(2)
            ))
        }
        group.addTask {
            await Task.yield()
            return .revocation(try revocationJournal.revokeRemoteDevice(
                id: remoteRaceDeviceID,
                expectedRevocationEpoch: 0,
                at: remoteRaceNow.addingTimeInterval(2)
            ))
        }
        var values: [RemoteRaceOutcome] = []
        for try await value in group { values.append(value) }
        return values
    }

    let commandResult = try #require(outcomes.compactMap { outcome -> GuardianRemoteReconciliation? in
        guard case let .command(result) = outcome else { return nil }
        return result
    }.first)
    let revoked = try #require(outcomes.compactMap { outcome -> GuardianRemoteDevice? in
        guard case let .revocation(device) = outcome else { return nil }
        return device
    }.first)
    #expect(revoked.status == .revoked)
    #expect(revoked.revocationEpoch == 1)

    let accepted: Bool
    switch commandResult {
    case .accepted:
        accepted = true
    case .rejected(.deviceRevoked):
        accepted = false
    default:
        Issue.record("Race produced a non-linearizable command result: \(commandResult)")
        return
    }

    let reopened = try GuardianJournal(databaseURL: databaseURL)
    let finalDevice = try #require(try reopened.remoteDevice(id: remoteRaceDeviceID))
    #expect(finalDevice.status == .revoked)
    #expect(finalDevice.revocationEpoch == 1)
    #expect(finalDevice.lastAcceptedSequence == (accepted ? 1 : 0))
    let audit = try reopened.remoteAuditEvents(limit: 20)
    #expect(audit.filter { $0.kind == .deviceRevoked }.count == 1)
    #expect(audit.filter { $0.kind == .commandAccepted }.count == (accepted ? 1 : 0))
}

private enum RemoteRaceOutcome: Sendable {
    case command(GuardianRemoteReconciliation)
    case revocation(GuardianRemoteDevice)
}

private func pairedRemoteRaceJournal(databaseURL: URL) throws -> GuardianJournal {
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let challenge = GuardianPairingChallenge(
        nonce: UUID(uuidString: "82000000-0000-0000-0000-000000000001")!,
        guardianIdentityHash: Data(repeating: 0x82, count: 32),
        expiresAt: remoteRaceNow.addingTimeInterval(60),
        consumedAt: nil
    )
    try journal.issuePairingChallenge(challenge, issuedAt: remoteRaceNow)
    try journal.pairRemoteDevice(
        GuardianRemoteDevice(
            id: remoteRaceDeviceID,
            publicKey: Data(repeating: 0x81, count: 32),
            capabilities: [.observe, .prompt, .policyRecovery],
            status: .active,
            pairingEpoch: 1,
            revocationEpoch: 0,
            lastAcceptedSequence: 0,
            pairedAt: remoteRaceNow.addingTimeInterval(1),
            lastSeenAt: nil
        ),
        challenge: challenge,
        at: remoteRaceNow.addingTimeInterval(1)
    )
    return journal
}

private func remoteRaceCommand() -> GuardianRemoteCommand {
    GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(uuidString: "83000000-0000-0000-0000-000000000001")!,
        deviceID: remoteRaceDeviceID,
        expectedGeneration: 42,
        sequence: 1,
        nonce: UUID(uuidString: "84000000-0000-0000-0000-000000000001")!,
        issuedAt: remoteRaceNow.addingTimeInterval(1),
        deadline: remoteRaceNow.addingTimeInterval(30),
        revocationEpoch: 0,
        targetThreadID: "thread-race",
        action: .prompt,
        force: false,
        payloadDigest: Data(repeating: 0x83, count: 32)
    )
}

private func remoteRaceDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-race-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
