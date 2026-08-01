import CryptoKit
import Foundation
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone pairing storage")
struct GuardianPhonePairingStorageTests {
    @Test("identity is stable and paired state survives storage recreation")
    func identityAndPairingRoundTrip() async throws {
        let backend = PhoneMemorySecureStorage()
        let key = Curve25519.Signing.PrivateKey()
        let deviceID = UUID()
        let storage = PhoneKeychainPairingStorage(
            backend: backend,
            identityGenerator: {
                PhoneDeviceIdentity(deviceID: deviceID, privateKey: key.rawRepresentation)
            }
        )

        let first = try await storage.loadOrCreateIdentity()
        let second = try await PhoneKeychainPairingStorage(backend: backend)
            .loadOrCreateIdentity()
        #expect(first == second)

        let pairing = PhonePairedGuardian(
            guardianID: UUID(),
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: deviceID,
            endpoint: .init(
                host: "192.168.1.20",
                port: 47_411,
                tlsCertificateHash: Data(repeating: 0x22, count: 32)
            ),
            capabilities: [.observe, .promptAgent],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: Date(timeIntervalSince1970: 8_002)
        )
        try await storage.save(pairing)

        let reloaded = try await PhoneKeychainPairingStorage(backend: backend).loadPairing()
        #expect(reloaded == pairing)
    }

    @Test("public stored endpoints are rejected before reconnect")
    func publicEndpointRejected() async throws {
        let storage = PhoneKeychainPairingStorage(backend: PhoneMemorySecureStorage())
        let pairing = PhonePairedGuardian(
            guardianID: UUID(),
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: UUID(),
            endpoint: .init(
                host: "8.8.8.8",
                port: 47_411,
                tlsCertificateHash: Data(repeating: 0x22, count: 32)
            ),
            capabilities: [.observe],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: Date(timeIntervalSince1970: 8_002)
        )

        await #expect(throws: PhoneSecureStorageError.invalidData) {
            try await storage.save(pairing)
        }
    }
}

private final class PhoneMemorySecureStorage: PhoneSecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func write(_ data: Data, account: String) throws {
        lock.withLock { values[account] = data }
    }
}
