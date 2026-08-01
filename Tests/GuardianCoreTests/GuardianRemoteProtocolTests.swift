import Foundation
import GuardianCore
import Testing

private let remoteNow = Date(timeIntervalSince1970: 1_000)
private let remoteDeviceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

private func remoteDevice(
    status: GuardianRemoteDeviceStatus = .active,
    capabilities: GuardianRemoteCapabilities = [.observe, .prompt, .policyRecovery],
    revocationEpoch: UInt64 = 2,
    lastAcceptedSequence: UInt64 = 4
) -> GuardianRemoteDevice {
    GuardianRemoteDevice(
        id: remoteDeviceID,
        publicKey: Data(repeating: 0xA5, count: 32),
        capabilities: capabilities,
        status: status,
        pairingEpoch: 1,
        revocationEpoch: revocationEpoch,
        lastAcceptedSequence: lastAcceptedSequence,
        pairedAt: remoteNow.addingTimeInterval(-100),
        lastSeenAt: remoteNow.addingTimeInterval(-1)
    )
}

private func remoteCommand(
    id: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
    sequence: UInt64 = 5,
    nonce: UUID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
    expectedGeneration: Int64 = 9,
    revocationEpoch: UInt64 = 2,
    action: GuardianRemoteAction = .prompt,
    force: Bool = false,
    payloadDigest: Data = Data(repeating: 0xC3, count: 32)
) -> GuardianRemoteCommand {
    GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: id,
        deviceID: remoteDeviceID,
        expectedGeneration: expectedGeneration,
        sequence: sequence,
        nonce: nonce,
        issuedAt: remoteNow.addingTimeInterval(-1),
        deadline: remoteNow.addingTimeInterval(30),
        revocationEpoch: revocationEpoch,
        targetThreadID: "thread-1",
        action: action,
        force: force,
        payloadDigest: payloadDigest
    )
}

@Test func replayedRemoteNonceIsRejected() {
    let result = GuardianRemoteCommandValidator().validate(
        remoteCommand(),
        device: remoteDevice(),
        currentGeneration: 9,
        consumedNonces: [remoteCommand().nonce],
        now: remoteNow
    )

    #expect(result == .rejected(.replayedNonce))
}

@Test func revokedRemoteDeviceIsRejectedBeforeCapabilityEvaluation() {
    let result = GuardianRemoteCommandValidator().validate(
        remoteCommand(action: .prompt),
        device: remoteDevice(status: .revoked, capabilities: []),
        currentGeneration: 9,
        consumedNonces: [],
        now: remoteNow
    )

    #expect(result == .rejected(.deviceRevoked))
}

@Test func wrongRemoteCapabilityIsRejected() {
    let result = GuardianRemoteCommandValidator().validate(
        remoteCommand(action: .approve),
        device: remoteDevice(capabilities: [.observe]),
        currentGeneration: 9,
        consumedNonces: [],
        now: remoteNow
    )

    #expect(result == .rejected(.missingCapability(.approve)))
}

@Test func staleRemoteGenerationRequiresSnapshot() {
    let result = GuardianRemoteCommandValidator().validate(
        remoteCommand(expectedGeneration: 8),
        device: remoteDevice(),
        currentGeneration: 9,
        consumedNonces: [],
        now: remoteNow
    )

    #expect(result == .snapshotRequired(.generationChanged(expected: 8, current: 9)))
}

@Test func firstRemoteObserveCanBootstrapWithoutKnownGeneration() {
    let result = GuardianRemoteCommandValidator().validate(
        remoteCommand(expectedGeneration: 0, action: .observe),
        device: remoteDevice(),
        currentGeneration: 9,
        consumedNonces: [],
        now: remoteNow
    )

    #expect(result == .accepted)
}

@Test func remoteMutationCannotBootstrapWithoutKnownGeneration() {
    let result = GuardianRemoteCommandValidator().validate(
        remoteCommand(expectedGeneration: 0, action: .prompt),
        device: remoteDevice(),
        currentGeneration: 9,
        consumedNonces: [],
        now: remoteNow
    )

    #expect(result == .snapshotRequired(.generationChanged(expected: 0, current: 9)))
}

@Test func offlineDuplicateReturnsOriginalReceiptWithoutSecondAcceptance() async {
    let ledger = GuardianRemoteCommandLedger()
    let command = remoteCommand()

    let first = await ledger.reconcile(
        command,
        device: remoteDevice(),
        currentGeneration: 9,
        now: remoteNow
    )
    let duplicate = await ledger.reconcile(
        command,
        device: remoteDevice(),
        currentGeneration: 9,
        now: remoteNow.addingTimeInterval(1)
    )

    guard case let .accepted(receipt) = first else {
        Issue.record("Expected first acceptance")
        return
    }
    #expect(duplicate == .duplicate(receipt))
    #expect(await ledger.acceptanceCount == 1)
}

@Test func reusedOfflineCommandIDWithChangedPayloadIsConflict() async {
    let ledger = GuardianRemoteCommandLedger()
    let command = remoteCommand()
    _ = await ledger.reconcile(
        command,
        device: remoteDevice(),
        currentGeneration: 9,
        now: remoteNow
    )

    let changed = remoteCommand(payloadDigest: Data(repeating: 0xD4, count: 32))
    let result = await ledger.reconcile(
        changed,
        device: remoteDevice(lastAcceptedSequence: 5),
        currentGeneration: 9,
        now: remoteNow.addingTimeInterval(1)
    )

    #expect(result == .rejected(.commandIDConflict))
    #expect(await ledger.acceptanceCount == 1)
}

@Test func remoteSequenceGapRequiresSnapshotBeforeAcceptance() {
    let result = GuardianRemoteCommandValidator().validate(
        remoteCommand(sequence: 7),
        device: remoteDevice(lastAcceptedSequence: 4),
        currentGeneration: 9,
        consumedNonces: [],
        now: remoteNow
    )

    #expect(result == .snapshotRequired(.sequenceGap(expected: 5, received: 7)))
}

@Test func remoteForceIsAlwaysRejectedEvenForPolicyRecoveryDevice() {
    let result = GuardianRemoteCommandValidator().validate(
        remoteCommand(action: .hardRecover, force: true),
        device: remoteDevice(capabilities: [.observe, .policyRecovery]),
        currentGeneration: 9,
        consumedNonces: [],
        now: remoteNow
    )

    #expect(result == .rejected(.remoteForceForbidden))
}

@Test func expiredOrConsumedPairingNonceCannotCreateDevice() {
    let identityHash = Data(repeating: 0xE5, count: 32)
    let expired = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: identityHash,
        expiresAt: remoteNow,
        consumedAt: nil
    )
    let consumed = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: identityHash,
        expiresAt: remoteNow.addingTimeInterval(30),
        consumedAt: remoteNow.addingTimeInterval(-1)
    )

    #expect(GuardianPairingPolicy().validate(
        expired,
        expectedGuardianIdentityHash: identityHash,
        now: remoteNow
    ) == .rejected(.expired))
    #expect(GuardianPairingPolicy().validate(
        consumed,
        expectedGuardianIdentityHash: identityHash,
        now: remoteNow
    ) == .rejected(.alreadyConsumed))
}

@Test func revocationTerminatesEveryActiveSessionForDevice() async {
    let hub = GuardianRemoteSessionHub()
    let first = UUID()
    let second = UUID()
    await hub.open(sessionID: first, device: remoteDevice(), cursor: .init(generation: 9, lastSequence: 4))
    await hub.open(sessionID: second, device: remoteDevice(), cursor: .init(generation: 9, lastSequence: 4))

    let closed = await hub.revoke(deviceID: remoteDeviceID, at: remoteNow)

    #expect(Set(closed) == [first, second])
    #expect(await hub.activeSessionCount(deviceID: remoteDeviceID) == 0)
}

@Test func reconnectSequenceGapBlocksEventsUntilFreshSnapshot() async {
    let hub = GuardianRemoteSessionHub()
    let sessionID = UUID()
    await hub.open(
        sessionID: sessionID,
        device: remoteDevice(),
        cursor: .init(generation: 9, lastSequence: 4)
    )

    #expect(await hub.receive(
        .init(generation: 9, sequence: 6),
        sessionID: sessionID
    ) == .snapshotRequired(.sequenceGap(expected: 5, received: 6)))
    #expect(await hub.receive(
        .init(generation: 9, sequence: 5),
        sessionID: sessionID
    ) == .snapshotRequired(.sessionAwaitingSnapshot))

    await hub.applySnapshot(
        .init(generation: 10, lastSequence: 20),
        sessionID: sessionID
    )
    #expect(await hub.receive(
        .init(generation: 10, sequence: 21),
        sessionID: sessionID
    ) == .accepted)
}

@Test func protocolOneObserveWithoutAckFieldRemainsCompatible() throws {
    let legacyPayload = Data(#"{"cursor":null,"maximumEvents":100}"#.utf8)

    let decoded = try JSONDecoder().decode(
        GuardianRemoteObserveRequest.self,
        from: legacyPayload
    )

    #expect(decoded == GuardianRemoteObserveRequest(cursor: nil, maximumEvents: 100))
    #expect(decoded.acknowledgedCommandIDs.isEmpty)
    #expect(GuardianRemoteObserveRequest(
        cursor: nil,
        acknowledgedCommandIDs: [remoteDeviceID, remoteDeviceID]
    ).isValid == false)
}
