import CryptoKit
import Foundation
import GuardianCore
import Testing

private let routerNow = Date(timeIntervalSince1970: 6_000)
private let routerGeneration: Int64 = 17

private enum RouterTestError: Error {
    case noPayloadKey
}

@Test func authenticatedObserveReturnsReceiptAndAuthoritativeSnapshot() async throws {
    let fixture = try routerFixture()
    let requestID = UUID(uuidString: "E0000000-0000-0000-0000-000000000001")!
    let snapshot = routerSnapshot()
    let probe = RouterSnapshotProbe(snapshot: snapshot)
    let router = GuardianRemoteRequestRouter(
        gateway: fixture.gateway,
        snapshotProvider: { try await probe.provide() }
    )
    let request = GuardianRemoteWireRequest(
        protocolVersion: .current,
        requestID: requestID,
        body: .command(try routerObservePacket(fixture: fixture))
    )

    let response = try await router.handle(
        request,
        currentGeneration: routerGeneration,
        now: routerNow.addingTimeInterval(2)
    )

    #expect(response.requestID == requestID)
    guard case let .observation(observation) = response.body else {
        Issue.record("Expected an explicit observe receipt and authoritative snapshot")
        return
    }
    #expect(observation.receipt.commandID == fixture.commandID)
    #expect(observation.receipt.deviceID == fixture.device.id)
    #expect(observation.snapshot == snapshot)
    #expect(await probe.callCount() == 1)
}

@Test func readOnlyObserveNeedsNoPayloadKeyAndCannotRemainQueued() async throws {
    let fixture = try routerFixture()
    let gateway = GuardianRemoteGatewayCore(
        journal: fixture.journal,
        payloadSealer: { _, _ in
            throw RouterTestError.noPayloadKey
        }
    )
    let router = GuardianRemoteRequestRouter(
        gateway: gateway,
        snapshotProvider: { routerSnapshot() }
    )
    let acceptedAt = routerNow.addingTimeInterval(2)

    let response = try await router.handle(
        .init(
            protocolVersion: .current,
            requestID: UUID(),
            body: .command(try routerObservePacket(fixture: fixture))
        ),
        currentGeneration: routerGeneration,
        now: acceptedAt
    )

    guard case .observation = response.body else {
        Issue.record("Read-only observe must not depend on payload-key availability")
        return
    }
    let outcome = try #require(try fixture.journal.remoteCommandOutcome(
        commandID: fixture.commandID
    ))
    #expect(outcome.state == .applied(at: acceptedAt))
    #expect(try fixture.journal.remoteCommandPayload(commandID: fixture.commandID) == nil)
    #expect(try fixture.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: routerGeneration,
        now: acceptedAt,
        leaseDuration: 10
    ) == nil)
}

@Test func forgedObserveNeverInvokesSnapshotProvider() async throws {
    let fixture = try routerFixture()
    let probe = RouterSnapshotProbe(snapshot: routerSnapshot())
    let router = GuardianRemoteRequestRouter(
        gateway: fixture.gateway,
        snapshotProvider: { try await probe.provide() }
    )
    let requestID = UUID(uuidString: "E0000000-0000-0000-0000-000000000002")!
    let forgedPacket = try routerObservePacket(
        fixture: fixture,
        signingKey: Curve25519.Signing.PrivateKey()
    )

    let response = try await router.handle(
        .init(
            protocolVersion: .current,
            requestID: requestID,
            body: .command(forgedPacket)
        ),
        currentGeneration: routerGeneration,
        now: routerNow.addingTimeInterval(2)
    )

    #expect(response.requestID == requestID)
    #expect(response.body == .gateway(.rejected(.signature(.invalidSignature))))
    #expect(await probe.callCount() == 0)
    #expect(try fixture.journal.remoteDevice(id: fixture.device.id)?.lastAcceptedSequence == 0)
}

@Test func unsignedSnapshotRequestIsRejectedWithoutProviderAccess() async throws {
    let fixture = try routerFixture()
    let probe = RouterSnapshotProbe(snapshot: routerSnapshot())
    let router = GuardianRemoteRequestRouter(
        gateway: fixture.gateway,
        snapshotProvider: { try await probe.provide() }
    )
    let requestID = UUID(uuidString: "E0000000-0000-0000-0000-000000000003")!

    let response = try await router.handle(
        .init(
            protocolVersion: .current,
            requestID: requestID,
            body: .snapshot(.init(
                deviceID: fixture.device.id,
                cursor: nil,
                deadline: routerNow.addingTimeInterval(30)
            ))
        ),
        currentGeneration: routerGeneration,
        now: routerNow.addingTimeInterval(2)
    )

    #expect(response == .init(
        protocolVersion: .current,
        requestID: requestID,
        body: .rejected(.unauthorized)
    ))
    #expect(await probe.callCount() == 0)
    #expect(try fixture.journal.remoteDevice(id: fixture.device.id)?.lastAcceptedSequence == 0)
}

@Test func pairingRequestUsesVerifierAndReturnsMinimalReceipt() async throws {
    let fixture = try routerFixture()
    let pairing = try routerPairingRequest()
    let pairedAt = routerNow.addingTimeInterval(2)
    let expected = GuardianRemotePairingReceipt(
        deviceID: pairing.claim.claim.deviceID,
        capabilities: pairing.claim.claim.requestedCapabilities,
        pairingEpoch: 1,
        revocationEpoch: 0,
        pairedAt: pairedAt
    )
    let probe = RouterPairingProbe(expected: expected)
    let router = GuardianRemoteRequestRouter(
        gateway: fixture.gateway,
        snapshotProvider: { routerSnapshot() },
        pairingHandler: { request, now in
            try await probe.complete(request, now: now)
        }
    )
    let requestID = UUID()

    let response = try await router.handle(
        .init(
            protocolVersion: .current,
            requestID: requestID,
            body: .pairing(pairing)
        ),
        currentGeneration: routerGeneration,
        now: pairedAt
    )

    #expect(response == .init(
        protocolVersion: .current,
        requestID: requestID,
        body: .paired(expected)
    ))
    #expect(await probe.callCount() == 1)
}

@Test func authenticatedObserveCursorReturnsReplayWithoutSnapshot() async throws {
    let fixture = try routerFixture()
    let snapshotProbe = RouterSnapshotProbe(snapshot: routerSnapshot())
    let cursor = GuardianIPCEventCursor(
        generation: routerGeneration,
        lastSequence: 81
    )
    let event = GuardianIPCEvent(
        generation: routerGeneration,
        sequence: 82,
        operationID: nil,
        emittedAt: routerNow.addingTimeInterval(2),
        kind: .taskChanged
    )
    let payload = try JSONEncoder().encode(
        GuardianRemoteObserveRequest(cursor: cursor, maximumEvents: 20)
    )
    let router = GuardianRemoteRequestRouter(
        gateway: fixture.gateway,
        snapshotProvider: { try await snapshotProbe.provide() },
        eventReplayProvider: { receivedCursor, limit in
            #expect(receivedCursor == cursor)
            #expect(limit == 20)
            return .events(
                [event],
                nextCursor: GuardianIPCEventCursor(
                    generation: routerGeneration,
                    lastSequence: event.sequence
                )
            )
        }
    )

    let response = try await router.handle(
        .init(
            protocolVersion: .current,
            requestID: UUID(),
            body: .command(try routerObservePacket(
                fixture: fixture,
                payload: payload
            ))
        ),
        currentGeneration: routerGeneration,
        now: routerNow.addingTimeInterval(2)
    )

    guard case let .eventBatch(batch) = response.body else {
        Issue.record("Expected authenticated replay batch")
        return
    }
    #expect(batch.events == [event])
    #expect(batch.nextCursor.lastSequence == event.sequence)
    #expect(await snapshotProbe.callCount() == 0)
}

@Test func noncontiguousReplayProviderOutputFallsBackToAuthoritativeSnapshot() async throws {
    let fixture = try routerFixture()
    let snapshot = routerSnapshot()
    let snapshotProbe = RouterSnapshotProbe(snapshot: snapshot)
    let cursor = GuardianIPCEventCursor(
        generation: routerGeneration,
        lastSequence: 81
    )
    let payload = try JSONEncoder().encode(
        GuardianRemoteObserveRequest(cursor: cursor, maximumEvents: 20)
    )
    let router = GuardianRemoteRequestRouter(
        gateway: fixture.gateway,
        snapshotProvider: { try await snapshotProbe.provide() },
        eventReplayProvider: { _, _ in
            .events(
                [.init(
                    generation: routerGeneration,
                    sequence: 83,
                    operationID: nil,
                    emittedAt: routerNow.addingTimeInterval(2),
                    kind: .taskChanged
                )],
                nextCursor: .init(generation: routerGeneration, lastSequence: 83)
            )
        }
    )

    let response = try await router.handle(
        .init(
            protocolVersion: .current,
            requestID: UUID(),
            body: .command(try routerObservePacket(
                fixture: fixture,
                payload: payload
            ))
        ),
        currentGeneration: routerGeneration,
        now: routerNow.addingTimeInterval(2)
    )

    guard case let .observation(observation) = response.body else {
        Issue.record("Invalid replay must fall back to authoritative snapshot")
        return
    }
    #expect(observation.snapshot == snapshot)
    #expect(await snapshotProbe.callCount() == 1)
}

private actor RouterSnapshotProbe {
    private let snapshot: GuardianIPCFullSnapshot
    private var calls = 0

    init(snapshot: GuardianIPCFullSnapshot) {
        self.snapshot = snapshot
    }

    func provide() throws -> GuardianIPCFullSnapshot {
        calls += 1
        return snapshot
    }

    func callCount() -> Int { calls }
}

private actor RouterPairingProbe {
    private let expected: GuardianRemotePairingReceipt
    private var calls = 0

    init(expected: GuardianRemotePairingReceipt) {
        self.expected = expected
    }

    func complete(
        _ request: GuardianRemotePairingRequest,
        now: Date
    ) throws -> GuardianRemotePairingReceipt {
        calls += 1
        #expect(request.claim.claim.deviceID == expected.deviceID)
        #expect(now == expected.pairedAt)
        return expected
    }

    func callCount() -> Int { calls }
}

private struct RouterFixture {
    let journal: GuardianJournal
    let gateway: GuardianRemoteGatewayCore
    let deviceKey: Curve25519.Signing.PrivateKey
    let device: GuardianRemoteDevice
    let commandID: UUID
}

private func routerFixture() throws -> RouterFixture {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-router-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let deviceKey = Curve25519.Signing.PrivateKey()
    let challenge = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: Data(repeating: 0x55, count: 32),
        expiresAt: routerNow.addingTimeInterval(60),
        consumedAt: nil
    )
    let device = GuardianRemoteDevice(
        id: UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!,
        publicKey: deviceKey.publicKey.rawRepresentation,
        capabilities: [.observe],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: routerNow.addingTimeInterval(1),
        lastSeenAt: nil
    )
    try journal.issuePairingChallenge(challenge, issuedAt: routerNow)
    try journal.pairRemoteDevice(
        device,
        challenge: challenge,
        at: routerNow.addingTimeInterval(1)
    )
    return RouterFixture(
        journal: journal,
        gateway: GuardianRemoteGatewayCore(
            journal: journal,
            payloadSealer: { try guardianTestPayloadSealer(command: $0, payload: $1) }
        ),
        deviceKey: deviceKey,
        device: device,
        commandID: UUID(uuidString: "C1000000-0000-0000-0000-000000000001")!
    )
}

private func routerObservePacket(
    fixture: RouterFixture,
    signingKey: Curve25519.Signing.PrivateKey? = nil,
    payload: Data = Data()
) throws -> GuardianRemoteCommandPacket {
    let command = GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: fixture.commandID,
        deviceID: fixture.device.id,
        expectedGeneration: routerGeneration,
        sequence: 1,
        nonce: UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!,
        issuedAt: routerNow.addingTimeInterval(1),
        deadline: routerNow.addingTimeInterval(30),
        revocationEpoch: fixture.device.revocationEpoch,
        targetThreadID: "router-thread",
        action: .observe,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
    let signed = try GuardianRemoteCommandAuthenticator().sign(
        command,
        using: signingKey ?? fixture.deviceKey
    )
    return GuardianRemoteCommandPacket(signedCommand: signed, payload: payload)
}

private func routerPairingRequest() throws -> GuardianRemotePairingRequest {
    let guardianKey = Curve25519.Signing.PrivateKey()
    let deviceKey = Curve25519.Signing.PrivateKey()
    let identityHash = Data(SHA256.hash(data: guardianKey.publicKey.rawRepresentation))
    let invitationPayload = GuardianPairingPayload(
        protocolVersion: .current,
        guardianID: UUID(),
        guardianPublicKey: guardianKey.publicKey.rawRepresentation,
        tlsCertificateHash: Data(repeating: 0x62, count: 32),
        endpointHost: "127.0.0.1",
        endpointPort: 9_443,
        challenge: .init(
            nonce: UUID(),
            guardianIdentityHash: identityHash,
            expiresAt: routerNow.addingTimeInterval(60),
            consumedAt: nil
        ),
        allowedCapabilities: [.observe, .prompt],
        issuedAt: routerNow
    )
    let claim = GuardianPairingClaim(
        protocolVersion: .current,
        guardianID: invitationPayload.guardianID,
        challengeNonce: invitationPayload.challenge.nonce,
        deviceID: UUID(),
        devicePublicKey: deviceKey.publicKey.rawRepresentation,
        requestedCapabilities: [.observe, .prompt],
        issuedAt: routerNow.addingTimeInterval(1)
    )
    return GuardianRemotePairingRequest(
        invitation: try GuardianPairingAuthenticator().sign(
            invitationPayload,
            using: guardianKey
        ),
        claim: try GuardianPairingClaimAuthenticator().sign(claim, using: deviceKey)
    )
}

private func routerSnapshot() -> GuardianIPCFullSnapshot {
    GuardianIPCFullSnapshot(
        protocolVersion: .current,
        generation: routerGeneration,
        lastSequence: 81,
        capturedAt: routerNow.addingTimeInterval(2),
        operations: [],
        tasks: [],
        taskInventoryCompleteness: .complete
    )
}
