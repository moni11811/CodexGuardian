import CryptoKit
import Foundation
import GuardianCore
import Testing

private let rejectionAuditNow = Date(timeIntervalSince1970: 7_000)
private let rejectionAuditDeviceID = UUID(
    uuidString: "E0000000-0000-0000-0000-000000000001"
)!

@Test func forgedRemoteAttemptIsDurablyAuditedWithoutSensitiveMaterial() async throws {
    let fixture = try rejectionAuditFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let payload = Data("private continuation prompt".utf8)
    let command = rejectionAuditCommand(payload: payload)
    let forged = try GuardianRemoteCommandAuthenticator().sign(
        command,
        using: Curve25519.Signing.PrivateKey()
    )
    let before = try fixture.journal.remoteAuditEvents(limit: 20)

    #expect(try await fixture.gateway.handle(
        GuardianRemoteCommandPacket(signedCommand: forged, payload: payload),
        currentGeneration: 7,
        now: rejectionAuditNow.addingTimeInterval(2)
    ) == .rejected(.signature(.invalidSignature)))

    let after = try fixture.journal.remoteAuditEvents(limit: 20)
    #expect(after.count == before.count + 1)
    let event = try #require(after.last)
    #expect(event.kind.rawValue == "commandRejected")
    #expect(event.reason == "command.rejected.invalid_signature")
    #expect(event.deviceID == command.deviceID)
    #expect(event.commandID == command.commandID)
    #expect(event.generation == 7)
    #expect(event.sequence == command.sequence)
    #expect(try fixture.journal.remoteDevice(id: command.deviceID)?.lastAcceptedSequence == 0)

    let encodedAudit = String(
        decoding: try JSONEncoder().encode(after),
        as: UTF8.self
    )
    #expect(!encodedAudit.localizedCaseInsensitiveContains(command.nonce.uuidString))
    #expect(!encodedAudit.contains(forged.signature.base64EncodedString()))
    #expect(!encodedAudit.contains(payload.base64EncodedString()))
    #expect(!encodedAudit.contains(String(decoding: payload, as: UTF8.self)))
}

@Test func replayedNonceIsAuditedWithoutAdvancingAcceptedSequence() throws {
    let fixture = try rejectionAuditFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accepted = rejectionAuditCommand()
    guard case .accepted = try fixture.journal.reconcileRemoteCommand(
        accepted,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 7,
        now: rejectionAuditNow.addingTimeInterval(2)
    ) else {
        Issue.record("Fixture command must be accepted")
        return
    }
    let replay = rejectionAuditCommand(
        commandID: UUID(uuidString: "E2000000-0000-0000-0000-000000000002")!,
        sequence: 2,
        nonce: accepted.nonce
    )
    let before = try fixture.journal.remoteAuditEvents(limit: 20)

    #expect(try fixture.journal.reconcileRemoteCommand(
        replay,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 7,
        now: rejectionAuditNow.addingTimeInterval(3)
    ) == .rejected(.replayedNonce))

    let after = try fixture.journal.remoteAuditEvents(limit: 20)
    #expect(after.count == before.count + 1)
    let event = try #require(after.last)
    #expect(event.kind.rawValue == "commandRejected")
    #expect(event.reason == "command.rejected.replayed_nonce")
    #expect(event.deviceID == replay.deviceID)
    #expect(event.commandID == replay.commandID)
    #expect(event.sequence == replay.sequence)
    #expect(try fixture.journal.remoteDevice(id: replay.deviceID)?.lastAcceptedSequence == 1)

    let encodedAudit = String(decoding: try JSONEncoder().encode(after), as: UTF8.self)
    #expect(!encodedAudit.localizedCaseInsensitiveContains(replay.nonce.uuidString))
}

@Test func revokedDeviceAttemptIsAuditedWithoutAdvancingAcceptedSequence() throws {
    let fixture = try rejectionAuditFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try fixture.journal.revokeRemoteDevice(
        id: rejectionAuditDeviceID,
        expectedRevocationEpoch: 0,
        at: rejectionAuditNow.addingTimeInterval(2)
    )
    let command = rejectionAuditCommand(revocationEpoch: 1)
    let before = try fixture.journal.remoteAuditEvents(limit: 20)

    #expect(try fixture.journal.reconcileRemoteCommand(
        command,
        sealedPayload: guardianTestSealedPayload(),
        currentGeneration: 7,
        now: rejectionAuditNow.addingTimeInterval(3)
    ) == .rejected(.deviceRevoked))

    let after = try fixture.journal.remoteAuditEvents(limit: 20)
    #expect(after.count == before.count + 1)
    let event = try #require(after.last)
    #expect(event.kind.rawValue == "commandRejected")
    #expect(event.reason == "command.rejected.device_revoked")
    #expect(event.deviceID == command.deviceID)
    #expect(event.commandID == command.commandID)
    #expect(event.sequence == command.sequence)
    #expect(try fixture.journal.remoteDevice(id: command.deviceID)?.lastAcceptedSequence == 0)
}

private struct RejectionAuditFixture {
    let directory: URL
    let journal: GuardianJournal
    let gateway: GuardianRemoteGatewayCore
}

private func rejectionAuditFixture() throws -> RejectionAuditFixture {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-rejection-audit-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let deviceKey = Curve25519.Signing.PrivateKey()
    let challenge = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: Data(repeating: 0xE1, count: 32),
        expiresAt: rejectionAuditNow.addingTimeInterval(60),
        consumedAt: nil
    )
    let device = GuardianRemoteDevice(
        id: rejectionAuditDeviceID,
        publicKey: deviceKey.publicKey.rawRepresentation,
        capabilities: [.observe, .prompt, .policyRecovery],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: rejectionAuditNow.addingTimeInterval(1),
        lastSeenAt: nil
    )
    try journal.issuePairingChallenge(challenge, issuedAt: rejectionAuditNow)
    try journal.pairRemoteDevice(
        device,
        challenge: challenge,
        at: rejectionAuditNow.addingTimeInterval(1)
    )
    return RejectionAuditFixture(
        directory: directory,
        journal: journal,
        gateway: GuardianRemoteGatewayCore(
            journal: journal,
            payloadSealer: { try guardianTestPayloadSealer(command: $0, payload: $1) }
        )
    )
}

private func rejectionAuditCommand(
    commandID: UUID = UUID(uuidString: "E2000000-0000-0000-0000-000000000001")!,
    sequence: UInt64 = 1,
    nonce: UUID = UUID(uuidString: "E3000000-0000-0000-0000-000000000001")!,
    revocationEpoch: UInt64 = 0,
    payload: Data = Data("private continuation prompt".utf8)
) -> GuardianRemoteCommand {
    GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: commandID,
        deviceID: rejectionAuditDeviceID,
        expectedGeneration: 7,
        sequence: sequence,
        nonce: nonce,
        issuedAt: rejectionAuditNow.addingTimeInterval(1),
        deadline: rejectionAuditNow.addingTimeInterval(30),
        revocationEpoch: revocationEpoch,
        targetThreadID: "rejection-audit-thread",
        action: .prompt,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
}
