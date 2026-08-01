import CryptoKit
import Foundation

public struct GuardianRemoteIdentity: Equatable, Sendable {
    public let publicKey: Data
    public let identityHash: Data

    public init(publicKey: Data, identityHash: Data) {
        self.publicKey = publicKey
        self.identityHash = identityHash
    }
}

public enum GuardianRemoteIdentityKeyError: Error, Equatable, Sendable {
    case invalidPrivateKey
    case duplicateItem
}

public actor GuardianRemoteIdentityKeyManager {
    public nonisolated let service: String
    public nonisolated let account: String

    private let storage: any GuardianSecretStorage
    private let generator: @Sendable () throws -> Data

    public init(
        storage: any GuardianSecretStorage = GuardianKeychainSecretStorage(),
        service: String = "com.moni.codexguardian.remote-identity",
        account: String = "mac",
        generator: @escaping @Sendable () throws -> Data = {
            Curve25519.Signing.PrivateKey().rawRepresentation
        }
    ) {
        self.storage = storage
        self.service = service
        self.account = account
        self.generator = generator
    }

    public func loadOrCreate() throws -> GuardianRemoteIdentity {
        let privateKey = try loadOrCreateSigningKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        return GuardianRemoteIdentity(
            publicKey: publicKey,
            identityHash: Data(SHA256.hash(data: publicKey))
        )
    }

    public func loadOrCreateSigningKey() throws -> Curve25519.Signing.PrivateKey {
        if let stored = try storage.read(service: service, account: account) {
            return try decode(stored)
        }
        let generated = try decode(generator())
        do {
            try storage.insert(
                generated.rawRepresentation,
                service: service,
                account: account
            )
            return generated
        } catch GuardianParentKeyError.duplicateItem {
            guard let raced = try storage.read(service: service, account: account) else {
                throw GuardianRemoteIdentityKeyError.duplicateItem
            }
            return try decode(raced)
        }
    }

    public func delete() throws {
        try storage.delete(service: service, account: account)
    }

    private func decode(_ data: Data) throws -> Curve25519.Signing.PrivateKey {
        guard data.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw GuardianRemoteIdentityKeyError.invalidPrivateKey
        }
        return key
    }
}
