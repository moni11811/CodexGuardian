import CryptoKit
import Foundation
import GuardianCore
import Testing

@Test func remoteWireCommandRoundTripsWithVersionAndRequestIdentity() throws {
    let packet = try wirePacket()
    let request = GuardianRemoteWireRequest(
        protocolVersion: .current,
        requestID: UUID(),
        body: .command(packet)
    )

    let frame = try GuardianRemoteWireCodec().encode(request)

    #expect(try GuardianRemoteWireCodec().decodeRequest(frame) == request)
    #expect(frame.count <= GuardianRemoteWireCodec.maximumFrameBytes + 4)
}

@Test func remoteWireCodecRejectsTruncationTrailingBytesAndOversize() throws {
    let frame = try GuardianRemoteWireCodec().encode(.init(
        protocolVersion: .current,
        requestID: UUID(),
        body: .command(try wirePacket())
    ))

    #expect(throws: GuardianRemoteWireError.truncated) {
        try GuardianRemoteWireCodec().decodeRequest(frame.dropLast())
    }
    #expect(throws: GuardianRemoteWireError.trailingBytes) {
        try GuardianRemoteWireCodec().decodeRequest(frame + [0])
    }
    let oversizedLength = UInt32(GuardianRemoteWireCodec.maximumFrameBytes + 1)
    let oversizedHeader = Data([
        UInt8((oversizedLength >> 24) & 0xff),
        UInt8((oversizedLength >> 16) & 0xff),
        UInt8((oversizedLength >> 8) & 0xff),
        UInt8(oversizedLength & 0xff),
    ])
    #expect(throws: GuardianRemoteWireError.oversized) {
        try GuardianRemoteWireCodec().decodeRequest(oversizedHeader)
    }
}

@Test func remoteWireCodecRejectsUnknownProtocolAndMalformedFuzzWithoutCrash() throws {
    let unsupported = GuardianRemoteWireRequest(
        protocolVersion: .init(major: 99, minor: 0),
        requestID: UUID(),
        body: .ping(UUID())
    )
    let frame = try GuardianRemoteWireCodec().encode(unsupported)
    #expect(throws: GuardianRemoteWireError.unsupportedProtocol(unsupported.protocolVersion)) {
        try GuardianRemoteWireCodec().decodeRequest(frame)
    }

    var generator = SeededWireGenerator(seed: 0xC0DE)
    for _ in 0..<500 {
        let count = Int.random(in: 0...1_024, using: &generator)
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        _ = try? GuardianRemoteWireCodec().decodeRequest(Data(bytes))
    }
}

@Test func remoteWireCodecRejectsUnsignedSnapshotBeforeRouting() throws {
    let request = GuardianRemoteWireRequest(
        protocolVersion: .current,
        requestID: UUID(),
        body: .snapshot(.init(
            deviceID: UUID(),
            cursor: nil,
            deadline: Date(timeIntervalSince1970: 5_030)
        ))
    )
    let frame = try GuardianRemoteWireCodec().encode(request)

    #expect(throws: GuardianRemoteWireError.unauthenticatedRequest) {
        try GuardianRemoteWireCodec().decodeRequest(frame)
    }
}

@Test func remoteWirePairingClaimRoundTripsBeforeDeviceExists() throws {
    let guardianKey = Curve25519.Signing.PrivateKey()
    let deviceKey = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 5_000)
    let identityHash = Data(SHA256.hash(data: guardianKey.publicKey.rawRepresentation))
    let payload = GuardianPairingPayload(
        protocolVersion: .current,
        guardianID: UUID(),
        guardianPublicKey: guardianKey.publicKey.rawRepresentation,
        tlsCertificateHash: Data(repeating: 0x7a, count: 32),
        endpointHost: "127.0.0.1",
        endpointPort: 9_443,
        challenge: GuardianPairingChallenge(
            nonce: UUID(),
            guardianIdentityHash: identityHash,
            expiresAt: now.addingTimeInterval(60),
            consumedAt: nil
        ),
        allowedCapabilities: [.observe, .prompt],
        issuedAt: now
    )
    let invitation = try GuardianPairingAuthenticator().sign(payload, using: guardianKey)
    let claim = GuardianPairingClaim(
        protocolVersion: .current,
        guardianID: payload.guardianID,
        challengeNonce: payload.challenge.nonce,
        deviceID: UUID(),
        devicePublicKey: deviceKey.publicKey.rawRepresentation,
        requestedCapabilities: [.observe, .prompt],
        issuedAt: now.addingTimeInterval(1)
    )
    let request = GuardianRemoteWireRequest(
        protocolVersion: .current,
        requestID: UUID(),
        body: .pairing(.init(
            invitation: invitation,
            claim: try GuardianPairingClaimAuthenticator().sign(claim, using: deviceKey)
        ))
    )

    let frame = try GuardianRemoteWireCodec().encode(request)

    #expect(try GuardianRemoteWireCodec().decodeRequest(frame) == request)
}

private func wirePacket() throws -> GuardianRemoteCommandPacket {
    let key = Curve25519.Signing.PrivateKey()
    let payload = Data("wire prompt".utf8)
    let command = GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(),
        deviceID: UUID(),
        expectedGeneration: 2,
        sequence: 1,
        nonce: UUID(),
        issuedAt: Date(timeIntervalSince1970: 5_000),
        deadline: Date(timeIntervalSince1970: 5_030),
        revocationEpoch: 0,
        targetThreadID: "wire-thread",
        action: .prompt,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
    return GuardianRemoteCommandPacket(
        signedCommand: try GuardianRemoteCommandAuthenticator().sign(command, using: key),
        payload: payload
    )
}

private struct SeededWireGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
