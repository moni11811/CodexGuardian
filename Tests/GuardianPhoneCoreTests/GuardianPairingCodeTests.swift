import CryptoKit
import Foundation
import GuardianCore
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone pairing code")
struct GuardianPairingCodeTests {
    @Test("signed invitation becomes a pinned private endpoint")
    func signedInvitationDecodesAndVerifies() throws {
        let now = Date(timeIntervalSince1970: 8_000)
        let guardianKey = Curve25519.Signing.PrivateKey()
        let identityHash = Data(SHA256.hash(data: guardianKey.publicKey.rawRepresentation))
        let payload = GuardianPairingPayload(
            protocolVersion: .current,
            guardianID: UUID(),
            guardianPublicKey: guardianKey.publicKey.rawRepresentation,
            tlsCertificateHash: Data(repeating: 0x4a, count: 32),
            endpointHost: "192.168.1.20",
            endpointPort: 47_411,
            challenge: .init(
                nonce: UUID(),
                guardianIdentityHash: identityHash,
                expiresAt: now.addingTimeInterval(60),
                consumedAt: nil
            ),
            allowedCapabilities: [.observe, .prompt],
            issuedAt: now
        )
        let signed = try GuardianPairingAuthenticator().sign(payload, using: guardianKey)
        let code = try GuardianPairingCode.encode(signed)

        let invitation = try PhonePairingCodeDecoder().decode(code, now: now.addingTimeInterval(1))

        #expect(invitation.guardianID == payload.guardianID)
        #expect(invitation.endpointHost == payload.endpointHost)
        #expect(invitation.endpointPort == payload.endpointPort)
        #expect(invitation.tlsCertificateHash == payload.tlsCertificateHash)
        #expect(invitation.challengeNonce == payload.challenge.nonce)
        #expect(invitation.allowedCapabilities == [.observe, .promptAgent])
    }

    @Test("tampered invitation is rejected")
    func tamperedInvitationIsRejected() throws {
        let now = Date(timeIntervalSince1970: 8_000)
        let guardianKey = Curve25519.Signing.PrivateKey()
        let identityHash = Data(SHA256.hash(data: guardianKey.publicKey.rawRepresentation))
        let forged = GuardianSignedPairingPayload(
            payload: GuardianPairingPayload(
                protocolVersion: .current,
                guardianID: UUID(),
                guardianPublicKey: guardianKey.publicKey.rawRepresentation,
                tlsCertificateHash: Data(repeating: 0x4a, count: 32),
                endpointHost: "192.168.1.20",
                endpointPort: 47_411,
                challenge: .init(
                    nonce: UUID(),
                    guardianIdentityHash: identityHash,
                    expiresAt: now.addingTimeInterval(60),
                    consumedAt: nil
                ),
                issuedAt: now
            ),
            signature: Data(repeating: 0, count: 64)
        )
        let code = try GuardianPairingCode.encode(forged)

        #expect(throws: PhonePairingCodeError.self) {
            try PhonePairingCodeDecoder().decode(code, now: now.addingTimeInterval(1))
        }
    }

    @Test("phone pairing claim is accepted by the Mac wire codec")
    func phoneClaimUsesMacWireFormat() throws {
        let now = Date(timeIntervalSince1970: 8_000)
        let guardianKey = Curve25519.Signing.PrivateKey()
        let deviceKey = Curve25519.Signing.PrivateKey()
        let identityHash = Data(SHA256.hash(data: guardianKey.publicKey.rawRepresentation))
        let payload = GuardianPairingPayload(
            protocolVersion: .current,
            guardianID: UUID(),
            guardianPublicKey: guardianKey.publicKey.rawRepresentation,
            tlsCertificateHash: Data(repeating: 0x4a, count: 32),
            endpointHost: "192.168.1.20",
            endpointPort: 47_411,
            challenge: .init(
                nonce: UUID(),
                guardianIdentityHash: identityHash,
                expiresAt: now.addingTimeInterval(60),
                consumedAt: nil
            ),
            allowedCapabilities: [.observe, .prompt],
            issuedAt: now
        )
        let code = try GuardianPairingCode.encode(
            try GuardianPairingAuthenticator().sign(payload, using: guardianKey)
        )
        let invitation = try PhonePairingCodeDecoder().decode(code, now: now)
        let deviceID = UUID()
        let requestID = UUID()

        let pending = try PhoneRemotePairingWireCodec().makeRequest(
            invitation: invitation,
            identity: PhoneDeviceIdentity(
                deviceID: deviceID,
                privateKey: deviceKey.rawRepresentation
            ),
            requestedActions: [.observe, .promptAgent],
            requestID: requestID,
            now: now.addingTimeInterval(1)
        )

        let decoded = try GuardianRemoteWireCodec().decodeRequest(pending.frame)
        #expect(decoded.requestID == requestID)
        guard case let .pairing(request) = decoded.body else {
            Issue.record("Expected Mac pairing wire request")
            return
        }
        #expect(request.invitation.payload == payload)
        #expect(request.claim.claim.deviceID == deviceID)
        #expect(request.claim.claim.devicePublicKey == deviceKey.publicKey.rawRepresentation)
        #expect(request.claim.claim.requestedCapabilities == [.observe, .prompt])
        #expect(try GuardianPairingClaimAuthenticator().verify(
            request.claim,
            invitation: payload,
            now: now.addingTimeInterval(2)
        ) == .authenticated(request.claim.claim))
    }

    @Test("phone decodes the Mac's minimal pairing receipt")
    func phoneDecodesMacPairingReceipt() throws {
        let requestID = UUID()
        let receipt = GuardianRemotePairingReceipt(
            deviceID: UUID(),
            capabilities: [.observe, .prompt],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: Date(timeIntervalSince1970: 8_002)
        )
        let frame = try GuardianRemoteWireCodec().encode(.init(
            protocolVersion: .current,
            requestID: requestID,
            body: .paired(receipt)
        ))

        let decoded = try PhoneRemotePairingWireCodec().decodeResponse(
            frame,
            expectedRequestID: requestID
        )

        #expect(decoded.deviceID == receipt.deviceID)
        #expect(decoded.pairingEpoch == receipt.pairingEpoch)
        #expect(decoded.revocationEpoch == receipt.revocationEpoch)
    }

    @Test("TLS pin matches only the exact leaf certificate DER")
    func tlsPinRequiresExactLeafCertificate() {
        let leaf = Data("guardian leaf certificate".utf8)
        let pin = Data(SHA256.hash(data: leaf))

        #expect(PhoneCertificatePin.matches(leafCertificateDER: leaf, expectedSHA256: pin))
        #expect(!PhoneCertificatePin.matches(
            leafCertificateDER: Data("other certificate".utf8),
            expectedSHA256: pin
        ))
        #expect(!PhoneCertificatePin.matches(leafCertificateDER: leaf, expectedSHA256: Data()))
    }
}
