import CryptoKit
import Foundation
import GuardianCore
import Testing

private let pairingValidationNow = Date(timeIntervalSince1970: 8_000)

@Test func pairingInvitationRejectsPublicEndpointBeforeTrust() throws {
    let guardianKey = Curve25519.Signing.PrivateKey()
    let identityHash = Data(SHA256.hash(data: guardianKey.publicKey.rawRepresentation))
    let payload = GuardianPairingPayload(
        protocolVersion: .current,
        guardianID: UUID(),
        guardianPublicKey: guardianKey.publicKey.rawRepresentation,
        tlsCertificateHash: Data(repeating: 0x77, count: 32),
        endpointHost: "203.0.113.9",
        endpointPort: 47_411,
        challenge: GuardianPairingChallenge(
            nonce: UUID(),
            guardianIdentityHash: identityHash,
            expiresAt: pairingValidationNow.addingTimeInterval(60),
            consumedAt: nil
        ),
        issuedAt: pairingValidationNow
    )
    let signed = try GuardianPairingAuthenticator().sign(payload, using: guardianKey)

    let result = try GuardianPairingAuthenticator().verify(
        signed,
        expectedIdentityHash: identityHash,
        now: pairingValidationNow.addingTimeInterval(1)
    )
    #expect(result == .rejected(.invalidPayload))
}

@Test func pairingClaimRejectsTimestampBeforeInvitationIssuance() throws {
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
            expiresAt: pairingValidationNow.addingTimeInterval(60),
            consumedAt: nil
        ),
        allowedCapabilities: [.observe],
        issuedAt: pairingValidationNow
    )
    let claim = GuardianPairingClaim(
        protocolVersion: .current,
        guardianID: invitation.guardianID,
        challengeNonce: invitation.challenge.nonce,
        deviceID: UUID(),
        devicePublicKey: deviceKey.publicKey.rawRepresentation,
        requestedCapabilities: [.observe],
        issuedAt: pairingValidationNow.addingTimeInterval(-1)
    )
    let signed = try GuardianPairingClaimAuthenticator().sign(claim, using: deviceKey)

    let result = try GuardianPairingClaimAuthenticator().verify(
        signed,
        invitation: invitation,
        now: pairingValidationNow.addingTimeInterval(1)
    )
    #expect(result == .rejected(.invalidClaim))
}
