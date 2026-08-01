import CryptoKit
import Foundation
import GuardianCore
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone pairing coordinator")
struct GuardianPhonePairingCoordinatorTests {
    @Test("pairing persists only after the matching Mac receipt")
    func pairingPersistsAfterMatchingReceipt() async throws {
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
        let identity = PhoneDeviceIdentity(
            deviceID: UUID(),
            privateKey: deviceKey.rawRepresentation
        )
        let storage = PairingStorageSpy(identity: identity)
        let coordinator = PhonePairingCoordinator(
            storage: storage,
            exchange: { endpoint, frame in
                #expect(endpoint.host == payload.endpointHost)
                #expect(endpoint.port == payload.endpointPort)
                #expect(endpoint.tlsCertificateHash == payload.tlsCertificateHash)
                let request = try GuardianRemoteWireCodec().decodeRequest(frame)
                guard case let .pairing(pairing) = request.body else {
                    throw PairingCoordinatorTestError.invalidRequest
                }
                return try GuardianRemoteWireCodec().encode(.init(
                    protocolVersion: .current,
                    requestID: request.requestID,
                    body: .paired(.init(
                        deviceID: pairing.claim.claim.deviceID,
                        capabilities: pairing.claim.claim.requestedCapabilities,
                        pairingEpoch: 1,
                        revocationEpoch: 0,
                        pairedAt: now.addingTimeInterval(2)
                    ))
                ))
            }
        )

        let paired = try await coordinator.pair(
            code: code,
            requestedActions: [.observe, .promptAgent],
            now: now.addingTimeInterval(1)
        )

        #expect(paired.deviceID == identity.deviceID)
        #expect(await storage.savedPairing() == paired)
    }
}

private enum PairingCoordinatorTestError: Error {
    case invalidRequest
}

private actor PairingStorageSpy: PhonePairingStorage {
    private let identity: PhoneDeviceIdentity
    private var saved: PhonePairedGuardian?

    init(identity: PhoneDeviceIdentity) {
        self.identity = identity
    }

    func loadOrCreateIdentity() throws -> PhoneDeviceIdentity { identity }
    func save(_ pairing: PhonePairedGuardian) throws { saved = pairing }
    func savedPairing() -> PhonePairedGuardian? { saved }
}
