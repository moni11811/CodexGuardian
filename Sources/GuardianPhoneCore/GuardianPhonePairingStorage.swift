import CryptoKit
import Foundation
import Security

public protocol PhoneSecureStorage: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
}

public enum PhoneSecureStorageError: Error, Equatable, Sendable {
    case unexpectedStatus(Int32)
    case invalidData
}

public struct PhoneKeychainSecureStorage: PhoneSecureStorage, Sendable {
    public let service: String

    public init(service: String = "com.moni.codexguardian.phone") {
        self.service = service
    }

    public func read(account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PhoneSecureStorageError.unexpectedStatus(status)
        }
        return data
    }

    public func write(_ data: Data, account: String) throws {
        guard !data.isEmpty else { throw PhoneSecureStorageError.invalidData }
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary
        let updated = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw PhoneSecureStorageError.unexpectedStatus(updated)
        }
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ] as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let raced = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
            guard raced == errSecSuccess else {
                throw PhoneSecureStorageError.unexpectedStatus(raced)
            }
            return
        }
        guard status == errSecSuccess else {
            throw PhoneSecureStorageError.unexpectedStatus(status)
        }
    }
}

public actor PhoneKeychainPairingStorage: PhonePairingStorage {
    public static let identityAccount = "device-identity-v1"
    public static let pairingAccount = "paired-guardian-v1"

    private let backend: any PhoneSecureStorage
    private let identityGenerator: @Sendable () throws -> PhoneDeviceIdentity

    public init(
        backend: any PhoneSecureStorage = PhoneKeychainSecureStorage(),
        identityGenerator: @escaping @Sendable () throws -> PhoneDeviceIdentity = {
            PhoneDeviceIdentity(
                deviceID: UUID(),
                privateKey: Curve25519.Signing.PrivateKey().rawRepresentation
            )
        }
    ) {
        self.backend = backend
        self.identityGenerator = identityGenerator
    }

    public func loadOrCreateIdentity() async throws -> PhoneDeviceIdentity {
        if let data = try backend.read(account: Self.identityAccount) {
            return try decodeIdentity(data)
        }
        let identity = try identityGenerator()
        guard identity.isValid else { throw PhoneSecureStorageError.invalidData }
        try backend.write(try encoder().encode(identity), account: Self.identityAccount)
        guard let persisted = try backend.read(account: Self.identityAccount) else {
            throw PhoneSecureStorageError.invalidData
        }
        return try decodeIdentity(persisted)
    }

    public func loadPairing() async throws -> PhonePairedGuardian? {
        guard let data = try backend.read(account: Self.pairingAccount) else { return nil }
        let pairing: PhonePairedGuardian
        do {
            pairing = try decoder().decode(PhonePairedGuardian.self, from: data)
        } catch {
            throw PhoneSecureStorageError.invalidData
        }
        guard Self.isValid(pairing) else { throw PhoneSecureStorageError.invalidData }
        return pairing
    }

    public func save(_ pairing: PhonePairedGuardian) async throws {
        guard Self.isValid(pairing) else { throw PhoneSecureStorageError.invalidData }
        try backend.write(try encoder().encode(pairing), account: Self.pairingAccount)
    }

    private func decodeIdentity(_ data: Data) throws -> PhoneDeviceIdentity {
        let identity: PhoneDeviceIdentity
        do {
            identity = try decoder().decode(PhoneDeviceIdentity.self, from: data)
        } catch {
            throw PhoneSecureStorageError.invalidData
        }
        guard identity.isValid else { throw PhoneSecureStorageError.invalidData }
        return identity
    }

    private static func isValid(_ pairing: PhonePairedGuardian) -> Bool {
        pairing.guardianPublicKey.count == 32
            && pairing.endpoint.isValid
            && pairing.capabilities.contains(.observe)
            && pairing.pairingEpoch > 0
            && pairing.pairedAt.timeIntervalSince1970.isFinite
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
