import CryptoKit
import Foundation
import GuardianCore
import Testing

private let cryptoNow = Date(timeIntervalSince1970: 3_000)

@Test func remoteCommandSignatureBindsEveryImmutableField() throws {
    let key = Curve25519.Signing.PrivateKey()
    let command = cryptoRemoteCommand(payloadDigest: Data(repeating: 0x11, count: 32))
    let signed = try GuardianRemoteCommandAuthenticator().sign(command, using: key)
    let device = cryptoRemoteDevice(publicKey: key.publicKey.rawRepresentation)

    #expect(try GuardianRemoteCommandAuthenticator().verify(
        signed,
        device: device
    ) == .authenticated(command))

    let tampered = GuardianRemoteSignedCommand(
        command: cryptoRemoteCommand(payloadDigest: Data(repeating: 0x22, count: 32)),
        signature: signed.signature
    )
    #expect(try GuardianRemoteCommandAuthenticator().verify(
        tampered,
        device: device
    ) == .rejected(.invalidSignature))
}

@Test func remoteCommandSignedByDifferentDeviceKeyIsRejected() throws {
    let signer = Curve25519.Signing.PrivateKey()
    let other = Curve25519.Signing.PrivateKey()
    let command = cryptoRemoteCommand()
    let signed = try GuardianRemoteCommandAuthenticator().sign(command, using: signer)

    #expect(try GuardianRemoteCommandAuthenticator().verify(
        signed,
        device: cryptoRemoteDevice(publicKey: other.publicKey.rawRepresentation)
    ) == .rejected(.invalidSignature))
}

@Test func pairingEnvelopePinsGuardianIdentityAndRejectsTampering() throws {
    let guardianKey = Curve25519.Signing.PrivateKey()
    let identityHash = Data(SHA256.hash(data: guardianKey.publicKey.rawRepresentation))
    let tlsCertificateHash = Data(SHA256.hash(data: Data("test-certificate".utf8)))
    let challenge = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: identityHash,
        expiresAt: cryptoNow.addingTimeInterval(60),
        consumedAt: nil
    )
    let payload = GuardianPairingPayload(
        protocolVersion: .current,
        guardianID: UUID(),
        guardianPublicKey: guardianKey.publicKey.rawRepresentation,
        tlsCertificateHash: tlsCertificateHash,
        endpointHost: "192.168.1.20",
        endpointPort: 47_411,
        challenge: challenge,
        issuedAt: cryptoNow
    )
    let signed = try GuardianPairingAuthenticator().sign(payload, using: guardianKey)

    #expect(try GuardianPairingAuthenticator().verify(
        signed,
        expectedIdentityHash: identityHash,
        now: cryptoNow
    ) == .authenticated(payload))

    let tamperedPayload = GuardianPairingPayload(
        protocolVersion: payload.protocolVersion,
        guardianID: payload.guardianID,
        guardianPublicKey: payload.guardianPublicKey,
        tlsCertificateHash: payload.tlsCertificateHash,
        endpointHost: "192.168.1.21",
        endpointPort: payload.endpointPort,
        challenge: payload.challenge,
        issuedAt: payload.issuedAt
    )
    let tampered = GuardianSignedPairingPayload(
        payload: tamperedPayload,
        signature: signed.signature
    )
    #expect(try GuardianPairingAuthenticator().verify(
        tampered,
        expectedIdentityHash: identityHash,
        now: cryptoNow
    ) == .rejected(.invalidSignature))
}

private func cryptoRemoteDevice(publicKey: Data) -> GuardianRemoteDevice {
    GuardianRemoteDevice(
        id: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!,
        publicKey: publicKey,
        capabilities: [.observe, .prompt],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: cryptoNow,
        lastSeenAt: nil
    )
}

private func cryptoRemoteCommand(
    payloadDigest: Data = Data(repeating: 0x11, count: 32)
) -> GuardianRemoteCommand {
    GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(uuidString: "90000000-0000-0000-0000-000000000001")!,
        deviceID: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!,
        expectedGeneration: 3,
        sequence: 1,
        nonce: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
        issuedAt: cryptoNow,
        deadline: cryptoNow.addingTimeInterval(30),
        revocationEpoch: 0,
        targetThreadID: "thread-crypto",
        action: .prompt,
        force: false,
        payloadDigest: payloadDigest
    )
}
