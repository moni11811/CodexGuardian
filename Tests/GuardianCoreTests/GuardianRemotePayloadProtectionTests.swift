import CryptoKit
import Foundation
import GuardianCore
import Testing

private let protectedRemoteNow = Date(timeIntervalSince1970: 8_000)
private let protectedRemoteGeneration: Int64 = 29

@Test func acceptedRemotePayloadIsEncryptedDurableAndRecoverableAfterReopen() async throws {
    let fixture = try protectedRemoteFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let parentKey = Data(repeating: 0x91, count: 32)
    let cipher = try GuardianRemotePayloadCipher(parentKeyData: parentKey)
    let gateway = GuardianRemoteGatewayCore(
        journal: fixture.journal,
        supportedActions: [.observe, .prompt],
        payloadSealer: { command, payload in
            try cipher.seal(payload, for: command)
        }
    )

    guard case .reconciled(.accepted) = try await gateway.handle(
        fixture.packet,
        currentGeneration: protectedRemoteGeneration,
        now: protectedRemoteNow.addingTimeInterval(2)
    ) else {
        Issue.record("Protected command was not accepted")
        return
    }

    let reopened = try GuardianJournal(databaseURL: fixture.databaseURL)
    let envelope = try #require(
        try reopened.remoteCommandPayload(commandID: fixture.command.commandID)
    )
    #expect(envelope.sealedPayload != fixture.packet.payload)
    #expect(try cipher.open(envelope, for: fixture.command) == fixture.packet.payload)
    let nonceRedactedIdentity = GuardianRemoteCommand(
        protocolVersion: fixture.command.protocolVersion,
        commandID: fixture.command.commandID,
        deviceID: fixture.command.deviceID,
        expectedGeneration: fixture.command.expectedGeneration,
        sequence: fixture.command.sequence,
        nonce: UUID(),
        issuedAt: fixture.command.issuedAt,
        deadline: fixture.command.deadline,
        revocationEpoch: fixture.command.revocationEpoch,
        targetThreadID: fixture.command.targetThreadID,
        action: fixture.command.action,
        force: fixture.command.force,
        payloadDigest: fixture.command.payloadDigest
    )
    #expect(try cipher.open(
        envelope,
        for: nonceRedactedIdentity
    ) == fixture.packet.payload)

    for suffix in ["", "-wal", "-shm"] {
        let file = URL(fileURLWithPath: fixture.databaseURL.path + suffix)
        guard let bytes = try? Data(contentsOf: file) else { continue }
        #expect(bytes.range(of: fixture.packet.payload) == nil)
    }
}

@Test func payloadSealingFailureConsumesNeitherNonceNorDeviceSequence() async throws {
    let fixture = try protectedRemoteFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let failingGateway = GuardianRemoteGatewayCore(
        journal: fixture.journal,
        supportedActions: [.observe, .prompt],
        payloadSealer: { _, _ in throw ProtectedRemoteFixtureError.sealingFailed }
    )

    #expect(try await failingGateway.handle(
        fixture.packet,
        currentGeneration: protectedRemoteGeneration,
        now: protectedRemoteNow.addingTimeInterval(2)
    ) == .rejected(.payloadProtectionUnavailable))
    #expect(try fixture.journal.remoteDevice(id: fixture.device.id)?.lastAcceptedSequence == 0)

    let cipher = try GuardianRemotePayloadCipher(parentKeyData: Data(repeating: 0x92, count: 32))
    let retryGateway = GuardianRemoteGatewayCore(
        journal: fixture.journal,
        supportedActions: [.observe, .prompt],
        payloadSealer: { command, payload in
            try cipher.seal(payload, for: command)
        }
    )
    guard case .reconciled(.accepted) = try await retryGateway.handle(
        fixture.packet,
        currentGeneration: protectedRemoteGeneration,
        now: protectedRemoteNow.addingTimeInterval(3)
    ) else {
        Issue.record("Sealing failure consumed replay state")
        return
    }
}

private enum ProtectedRemoteFixtureError: Error {
    case sealingFailed
}

private struct ProtectedRemoteFixture {
    let directory: URL
    let databaseURL: URL
    let journal: GuardianJournal
    let device: GuardianRemoteDevice
    let command: GuardianRemoteCommand
    let packet: GuardianRemoteCommandPacket
}

private func protectedRemoteFixture() throws -> ProtectedRemoteFixture {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-protected-remote-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appending(path: "guardian.sqlite")
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let deviceKey = Curve25519.Signing.PrivateKey()
    let identityHash = Data(repeating: 0x93, count: 32)
    let challenge = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: identityHash,
        expiresAt: protectedRemoteNow.addingTimeInterval(60),
        consumedAt: nil
    )
    let device = GuardianRemoteDevice(
        id: UUID(),
        publicKey: deviceKey.publicKey.rawRepresentation,
        capabilities: [.observe, .prompt],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: protectedRemoteNow.addingTimeInterval(1),
        lastSeenAt: nil
    )
    try journal.issuePairingChallenge(challenge, issuedAt: protectedRemoteNow)
    try journal.pairRemoteDevice(
        device,
        challenge: challenge,
        at: protectedRemoteNow.addingTimeInterval(1)
    )
    let payload = Data("UNIQUE_REMOTE_SECRET_6D88B1AA".utf8)
    let command = GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(),
        deviceID: device.id,
        expectedGeneration: protectedRemoteGeneration,
        sequence: 1,
        nonce: UUID(),
        issuedAt: protectedRemoteNow.addingTimeInterval(1),
        deadline: protectedRemoteNow.addingTimeInterval(30),
        revocationEpoch: 0,
        targetThreadID: "protected-remote-thread",
        action: .prompt,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
    return ProtectedRemoteFixture(
        directory: directory,
        databaseURL: databaseURL,
        journal: journal,
        device: device,
        command: command,
        packet: .init(
            signedCommand: try GuardianRemoteCommandAuthenticator().sign(
                command,
                using: deviceKey
            ),
            payload: payload
        )
    )
}
