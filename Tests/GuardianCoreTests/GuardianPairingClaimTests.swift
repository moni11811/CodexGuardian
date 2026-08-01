import CryptoKit
import Foundation
import GuardianCore
import Testing

private let claimNow = Date(timeIntervalSince1970: 7_000)

@Test func pairingClaimProvesDeviceKeyAndBindsInvitationCapabilities() throws {
    let guardianKey = Curve25519.Signing.PrivateKey()
    let deviceKey = Curve25519.Signing.PrivateKey()
    let identityHash = Data(SHA256.hash(data: guardianKey.publicKey.rawRepresentation))
    let invitation = GuardianPairingPayload(
        protocolVersion: .current,
        guardianID: UUID(),
        guardianPublicKey: guardianKey.publicKey.rawRepresentation,
        tlsCertificateHash: Data(repeating: 0x77, count: 32),
        endpointHost: "192.168.1.20",
        endpointPort: 47_411,
        challenge: GuardianPairingChallenge(
            nonce: UUID(),
            guardianIdentityHash: identityHash,
            expiresAt: claimNow.addingTimeInterval(60),
            consumedAt: nil
        ),
        allowedCapabilities: [.observe, .prompt],
        issuedAt: claimNow
    )
    let claim = GuardianPairingClaim(
        protocolVersion: .current,
        guardianID: invitation.guardianID,
        challengeNonce: invitation.challenge.nonce,
        deviceID: UUID(),
        devicePublicKey: deviceKey.publicKey.rawRepresentation,
        requestedCapabilities: [.observe, .prompt],
        issuedAt: claimNow.addingTimeInterval(1)
    )
    let authenticator = GuardianPairingClaimAuthenticator()
    let signed = try authenticator.sign(claim, using: deviceKey)

    #expect(try authenticator.verify(
        signed,
        invitation: invitation,
        now: claimNow.addingTimeInterval(2)
    ) == .authenticated(claim))

    let overprivileged = GuardianPairingClaim(
        protocolVersion: claim.protocolVersion,
        guardianID: claim.guardianID,
        challengeNonce: claim.challengeNonce,
        deviceID: claim.deviceID,
        devicePublicKey: claim.devicePublicKey,
        requestedCapabilities: [.observe, .prompt, .terminal],
        issuedAt: claim.issuedAt
    )
    #expect(try authenticator.verify(
        GuardianSignedPairingClaim(claim: overprivileged, signature: signed.signature),
        invitation: invitation,
        now: claimNow.addingTimeInterval(2)
    ) == .rejected(.capabilityEscalation))
}

@Test func forgedPairingClaimCannotCreateDurableDeviceTrust() throws {
    let deviceKey = Curve25519.Signing.PrivateKey()
    let attackerKey = Curve25519.Signing.PrivateKey()
    let invitation = claimInvitation()
    let claim = GuardianPairingClaim(
        protocolVersion: .current,
        guardianID: invitation.guardianID,
        challengeNonce: invitation.challenge.nonce,
        deviceID: UUID(),
        devicePublicKey: deviceKey.publicKey.rawRepresentation,
        requestedCapabilities: [.observe],
        issuedAt: claimNow.addingTimeInterval(1)
    )
    let forged = try GuardianPairingClaimAuthenticator().sign(claim, using: attackerKey)

    #expect(try GuardianPairingClaimAuthenticator().verify(
        forged,
        invitation: invitation,
        now: claimNow.addingTimeInterval(2)
    ) == .rejected(.invalidSignature))
}

@Test func pairingCoordinatorCreatesTrustOnceAfterSignedDeviceClaim() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-pairing-coordinator-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let guardianKey = Curve25519.Signing.PrivateKey()
    let keyManager = GuardianRemoteIdentityKeyManager(
        storage: PairingMemorySecretStorage(),
        generator: { guardianKey.rawRepresentation }
    )
    let coordinator = GuardianPairingCoordinator(
        journal: journal,
        guardianID: UUID(),
        identityKeyManager: keyManager
    )
    let signedInvitation = try await coordinator.issueInvitation(
        endpointHost: "192.168.1.20",
        endpointPort: 47_411,
        tlsCertificateHash: Data(repeating: 0x77, count: 32),
        allowedCapabilities: [.observe, .prompt],
        lifetime: 60,
        now: claimNow
    )
    let deviceKey = Curve25519.Signing.PrivateKey()
    let claim = GuardianPairingClaim(
        protocolVersion: .current,
        guardianID: signedInvitation.payload.guardianID,
        challengeNonce: signedInvitation.payload.challenge.nonce,
        deviceID: UUID(),
        devicePublicKey: deviceKey.publicKey.rawRepresentation,
        requestedCapabilities: [.observe, .prompt],
        issuedAt: claimNow.addingTimeInterval(1)
    )
    let signedClaim = try GuardianPairingClaimAuthenticator().sign(claim, using: deviceKey)

    let device = try await coordinator.completePairing(
        invitation: signedInvitation,
        claim: signedClaim,
        now: claimNow.addingTimeInterval(2)
    )

    #expect(device.id == claim.deviceID)
    #expect(try journal.remoteDevice(id: device.id) == device)
    await #expect(throws: GuardianJournalError.pairingChallengeConsumed) {
        try await coordinator.completePairing(
            invitation: signedInvitation,
            claim: signedClaim,
            now: claimNow.addingTimeInterval(3)
        )
    }
}

@Test func remotePairingCompletionPersistsDeviceAndReturnsReceipt() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-pairing-wire-completion-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let guardianKey = Curve25519.Signing.PrivateKey()
    let keyManager = GuardianRemoteIdentityKeyManager(
        storage: PairingMemorySecretStorage(),
        generator: { guardianKey.rawRepresentation }
    )
    let coordinator = GuardianPairingCoordinator(
        journal: journal,
        guardianID: UUID(),
        identityKeyManager: keyManager
    )
    let invitation = try await coordinator.issueInvitation(
        endpointHost: "192.168.1.20",
        endpointPort: 47_411,
        tlsCertificateHash: Data(repeating: 0x77, count: 32),
        allowedCapabilities: [.observe, .prompt],
        now: claimNow
    )
    let deviceKey = Curve25519.Signing.PrivateKey()
    let claim = GuardianPairingClaim(
        protocolVersion: .current,
        guardianID: invitation.payload.guardianID,
        challengeNonce: invitation.payload.challenge.nonce,
        deviceID: UUID(),
        devicePublicKey: deviceKey.publicKey.rawRepresentation,
        requestedCapabilities: [.observe, .prompt],
        issuedAt: claimNow.addingTimeInterval(1)
    )
    let request = GuardianRemotePairingRequest(
        invitation: invitation,
        claim: try GuardianPairingClaimAuthenticator().sign(claim, using: deviceKey)
    )

    let receipt = try await GuardianRemotePairingCompletion(
        journal: journal,
        identityKeyManager: keyManager
    ).complete(request, now: claimNow.addingTimeInterval(2))

    #expect(receipt.deviceID == claim.deviceID)
    #expect(receipt.capabilities == claim.requestedCapabilities)
    #expect(receipt.pairingEpoch == 1)
    #expect(receipt.revocationEpoch == 0)
    #expect(try journal.remoteDevice(id: claim.deviceID)?.publicKey == deviceKey.publicKey.rawRepresentation)
}

@Test func pairingCoordinatorDurablyAuditsForgedClaimWithoutCreatingTrust() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-pairing-rejection-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let guardianKey = Curve25519.Signing.PrivateKey()
    let coordinator = GuardianPairingCoordinator(
        journal: journal,
        guardianID: UUID(),
        identityKeyManager: GuardianRemoteIdentityKeyManager(
            storage: PairingMemorySecretStorage(),
            generator: { guardianKey.rawRepresentation }
        )
    )
    let invitation = try await coordinator.issueInvitation(
        endpointHost: "192.168.1.20",
        endpointPort: 47_411,
        tlsCertificateHash: Data(repeating: 0x77, count: 32),
        allowedCapabilities: [.observe],
        now: claimNow
    )
    let deviceKey = Curve25519.Signing.PrivateKey()
    let claim = GuardianPairingClaim(
        protocolVersion: .current,
        guardianID: invitation.payload.guardianID,
        challengeNonce: invitation.payload.challenge.nonce,
        deviceID: UUID(),
        devicePublicKey: deviceKey.publicKey.rawRepresentation,
        requestedCapabilities: [.observe],
        issuedAt: claimNow.addingTimeInterval(1)
    )
    let forged = try GuardianPairingClaimAuthenticator().sign(
        claim,
        using: Curve25519.Signing.PrivateKey()
    )
    let before = try journal.remoteAuditEvents(limit: 20)

    await #expect(throws: GuardianPairingCoordinatorError.claimRejected(.invalidSignature)) {
        try await coordinator.completePairing(
            invitation: invitation,
            claim: forged,
            now: claimNow.addingTimeInterval(2)
        )
    }

    let after = try journal.remoteAuditEvents(limit: 20)
    #expect(after.count == before.count + 1)
    let event = try #require(after.last)
    #expect(event.kind.rawValue == "pairingRejected")
    #expect(event.reason == "pairing.rejected.claim.invalid_signature")
    #expect(event.deviceID == claim.deviceID)
    #expect(event.commandID == nil)
    #expect(try journal.remoteDevice(id: claim.deviceID) == nil)
}

private final class PairingMemorySecretStorage: GuardianSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { value }
    }

    func insert(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            guard value == nil else { throw GuardianParentKeyError.duplicateItem }
            value = data
        }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { value = nil }
    }
}

private func claimInvitation() -> GuardianPairingPayload {
    let key = Curve25519.Signing.PrivateKey()
    let identityHash = Data(SHA256.hash(data: key.publicKey.rawRepresentation))
    return GuardianPairingPayload(
        protocolVersion: .current,
        guardianID: UUID(),
        guardianPublicKey: key.publicKey.rawRepresentation,
        tlsCertificateHash: Data(repeating: 0x77, count: 32),
        endpointHost: "192.168.1.20",
        endpointPort: 47_411,
        challenge: .init(
            nonce: UUID(),
            guardianIdentityHash: identityHash,
            expiresAt: claimNow.addingTimeInterval(60),
            consumedAt: nil
        ),
        allowedCapabilities: [.observe],
        issuedAt: claimNow
    )
}
