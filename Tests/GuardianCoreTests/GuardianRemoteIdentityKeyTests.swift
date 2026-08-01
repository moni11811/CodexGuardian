import CryptoKit
import Foundation
import GuardianCore
import Testing

private final class RemoteIdentityMemoryStorage: GuardianSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    init(value: Data? = nil) { self.value = value }

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

@Test func guardianRemoteIdentityIsStableAndPinnedAcrossLoads() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let storage = RemoteIdentityMemoryStorage()
    let manager = GuardianRemoteIdentityKeyManager(
        storage: storage,
        generator: { key.rawRepresentation }
    )

    let first = try await manager.loadOrCreate()
    let second = try await manager.loadOrCreate()

    #expect(first == second)
    #expect(first.publicKey == key.publicKey.rawRepresentation)
    #expect(first.identityHash == Data(SHA256.hash(data: first.publicKey)))
}

@Test func guardianRemoteIdentityRejectsMalformedKeychainMaterial() async {
    let manager = GuardianRemoteIdentityKeyManager(
        storage: RemoteIdentityMemoryStorage(value: Data(repeating: 1, count: 31))
    )

    await #expect(throws: GuardianRemoteIdentityKeyError.invalidPrivateKey) {
        try await manager.loadOrCreate()
    }
}
