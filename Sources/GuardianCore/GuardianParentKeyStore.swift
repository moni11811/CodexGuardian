import Foundation
import Security

public enum GuardianParentKeyError: Error, Equatable, Sendable {
    case invalidKeyMaterial
    case duplicateItem
    case keychain(OSStatus)
}

public protocol GuardianSecretStorage: Sendable {
    func read(service: String, account: String) throws -> Data?
    func insert(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct GuardianKeychainSecretStorage: GuardianSecretStorage, Sendable {
    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GuardianParentKeyError.keychain(status)
        }
        return data
    }

    public func insert(_ data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw GuardianParentKeyError.duplicateItem }
        guard status == errSecSuccess else { throw GuardianParentKeyError.keychain(status) }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GuardianParentKeyError.keychain(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public actor GuardianParentKeyManager {
    public nonisolated let service: String
    public nonisolated let account: String

    private let storage: any GuardianSecretStorage
    private let generator: @Sendable () throws -> Data

    public init(
        storage: any GuardianSecretStorage = GuardianKeychainSecretStorage(),
        service: String = "com.moni.codexguardian.payload-parent-key",
        account: String = "default",
        generator: @escaping @Sendable () throws -> Data = GuardianParentKeyManager.generateKey
    ) {
        self.storage = storage
        self.service = service
        self.account = account
        self.generator = generator
    }

    public func loadOrCreate() throws -> Data {
        if let stored = try storage.read(service: service, account: account) {
            return try validate(stored)
        }
        let generated = try validate(generator())
        do {
            try storage.insert(generated, service: service, account: account)
            return generated
        } catch GuardianParentKeyError.duplicateItem {
            guard let raced = try storage.read(service: service, account: account) else {
                throw GuardianParentKeyError.duplicateItem
            }
            return try validate(raced)
        }
    }

    public func delete() throws {
        try storage.delete(service: service, account: account)
    }

    public static func generateKey() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw GuardianParentKeyError.keychain(status)
        }
        return data
    }

    private func validate(_ data: Data) throws -> Data {
        guard data.count == 32 else { throw GuardianParentKeyError.invalidKeyMaterial }
        return data
    }
}
