import CryptoKit
import Foundation
import GuardianCore
import Testing

private let gatewayNow = Date(timeIntervalSince1970: 4_000)
private let gatewayPayload = Data("continue exact task".utf8)

@Test func forgedRemoteCommandCannotReachDurableLedger() async throws {
    let fixture = try gatewayFixture()
    let attacker = Curve25519.Signing.PrivateKey()
    let command = gatewayCommand()
    let forged = try GuardianRemoteCommandAuthenticator().sign(command, using: attacker)
    let packet = GuardianRemoteCommandPacket(signedCommand: forged, payload: gatewayPayload)

    #expect(try await fixture.gateway.handle(
        packet,
        currentGeneration: 7,
        now: gatewayNow.addingTimeInterval(2)
    ) == .rejected(.signature(.invalidSignature)))
    #expect(try fixture.journal.remoteDevice(id: fixture.device.id)?.lastAcceptedSequence == 0)
    #expect(try fixture.journal.remoteAuditEvents(limit: 20).allSatisfy {
        $0.kind != .commandAccepted
    })
}

@Test func authenticatedRemoteCommandIsAcceptedOnceByGateway() async throws {
    let fixture = try gatewayFixture()
    let command = gatewayCommand()
    let signed = try GuardianRemoteCommandAuthenticator().sign(command, using: fixture.deviceKey)
    let packet = GuardianRemoteCommandPacket(signedCommand: signed, payload: gatewayPayload)

    let first = try await fixture.gateway.handle(
        packet,
        currentGeneration: 7,
        now: gatewayNow.addingTimeInterval(2)
    )
    guard case let .reconciled(.accepted(receipt)) = first else {
        Issue.record("Expected authenticated command acceptance")
        return
    }
    #expect(try await fixture.gateway.handle(
        packet,
        currentGeneration: 8,
        now: gatewayNow.addingTimeInterval(3)
    ) == .reconciled(.duplicate(receipt)))
}

@Test func payloadDigestMismatchCannotReachSignatureOrJournal() async throws {
    let fixture = try gatewayFixture()
    let signed = try GuardianRemoteCommandAuthenticator().sign(
        gatewayCommand(),
        using: fixture.deviceKey
    )
    let tampered = GuardianRemoteCommandPacket(
        signedCommand: signed,
        payload: Data("different prompt".utf8)
    )

    #expect(try await fixture.gateway.handle(
        tampered,
        currentGeneration: 7,
        now: gatewayNow.addingTimeInterval(2)
    ) == .rejected(.payloadDigestMismatch))
    #expect(try fixture.journal.remoteDevice(id: fixture.device.id)?.lastAcceptedSequence == 0)
}

@Test func malformedSignedObservePayloadCannotAdvanceRemoteSequence() async throws {
    let fixture = try gatewayFixture()
    let malformedPayload = Data("{not-json".utf8)
    let command = gatewayCommand(action: .observe, payload: malformedPayload)
    let signed = try GuardianRemoteCommandAuthenticator().sign(
        command,
        using: fixture.deviceKey
    )

    #expect(try await fixture.gateway.handle(
        GuardianRemoteCommandPacket(
            signedCommand: signed,
            payload: malformedPayload
        ),
        currentGeneration: 7,
        now: gatewayNow.addingTimeInterval(2)
    ) == .rejected(.invalidPayload))
    #expect(try fixture.journal.remoteDevice(id: fixture.device.id)?.lastAcceptedSequence == 0)
    #expect(try fixture.journal.remoteAuditEvents(limit: 20).allSatisfy {
        $0.kind != .commandAccepted
    })
}

@Test func serverUnsupportedActionIsRejectedBeforeDurableAcceptance() async throws {
    let fixture = try gatewayFixture(supportedActions: [.observe])
    let command = gatewayCommand()
    let packet = GuardianRemoteCommandPacket(
        signedCommand: try GuardianRemoteCommandAuthenticator().sign(
            command,
            using: fixture.deviceKey
        ),
        payload: gatewayPayload
    )

    #expect(try await fixture.gateway.handle(
        packet,
        currentGeneration: 7,
        now: gatewayNow.addingTimeInterval(2)
    ) == .rejected(.adapterUnavailable))
    #expect(try fixture.journal.remoteDevice(id: fixture.device.id)?.lastAcceptedSequence == 0)
    #expect(try fixture.journal.remoteCommandOutcome(commandID: command.commandID) == nil)
}

@Test func durableGatewayRevocationClosesActiveSessions() async throws {
    let fixture = try gatewayFixture()
    let sessionID = UUID()
    #expect(try await fixture.gateway.openSession(
        id: sessionID,
        deviceID: fixture.device.id,
        cursor: .init(generation: 7, lastSequence: 0)
    ))

    let result = try await fixture.gateway.revokeDevice(
        id: fixture.device.id,
        expectedRevocationEpoch: 0,
        at: gatewayNow.addingTimeInterval(2)
    )

    #expect(result.device.status == .revoked)
    #expect(result.closedSessionIDs == [sessionID])
    #expect(await fixture.gateway.activeSessionCount(deviceID: fixture.device.id) == 0)
}

private struct GatewayFixture {
    let journal: GuardianJournal
    let gateway: GuardianRemoteGatewayCore
    let deviceKey: Curve25519.Signing.PrivateKey
    let device: GuardianRemoteDevice
}

private func gatewayFixture(
    supportedActions: [GuardianRemoteAction] = [.observe, .prompt]
) throws -> GatewayFixture {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-gateway-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let deviceKey = Curve25519.Signing.PrivateKey()
    let identityHash = Data(repeating: 0x44, count: 32)
    let challenge = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: identityHash,
        expiresAt: gatewayNow.addingTimeInterval(60),
        consumedAt: nil
    )
    let device = GuardianRemoteDevice(
        id: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
        publicKey: deviceKey.publicKey.rawRepresentation,
        capabilities: [.observe, .prompt, .policyRecovery],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: gatewayNow.addingTimeInterval(1),
        lastSeenAt: nil
    )
    try journal.issuePairingChallenge(challenge, issuedAt: gatewayNow)
    try journal.pairRemoteDevice(
        device,
        challenge: challenge,
        at: gatewayNow.addingTimeInterval(1)
    )
    return GatewayFixture(
        journal: journal,
        gateway: GuardianRemoteGatewayCore(
            journal: journal,
            supportedActions: supportedActions,
            payloadSealer: { try guardianTestPayloadSealer(command: $0, payload: $1) }
        ),
        deviceKey: deviceKey,
        device: device
    )
}

private func gatewayCommand(
    action: GuardianRemoteAction = .prompt,
    payload: Data = gatewayPayload
) -> GuardianRemoteCommand {
    GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!,
        deviceID: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
        expectedGeneration: 7,
        sequence: 1,
        nonce: UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!,
        issuedAt: gatewayNow.addingTimeInterval(1),
        deadline: gatewayNow.addingTimeInterval(30),
        revocationEpoch: 0,
        targetThreadID: "gateway-thread",
        action: action,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
}
