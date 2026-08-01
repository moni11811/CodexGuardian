import Foundation
import Security

public enum GuardianRemoteTLSIdentityLocatorError: Error, Equatable, Sendable {
    case invalidLabel
    case identityNotFound
    case keychainFailure(OSStatus)
    case invalidIdentityReference
}

public final class GuardianRemoteTLSIdentityLocator: @unchecked Sendable {
    public typealias Query = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus

    private let query: Query

    public init(query: @escaping Query = { attributes, result in
        SecItemCopyMatching(attributes, result)
    }) {
        self.query = query
    }

    public func load(label: String) throws -> SecIdentity {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == label,
              trimmed.utf8.count <= 256 else {
            throw GuardianRemoteTLSIdentityLocatorError.invalidLabel
        }
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: trimmed,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        let status = query(attributes as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw GuardianRemoteTLSIdentityLocatorError.identityNotFound
        }
        guard status == errSecSuccess else {
            throw GuardianRemoteTLSIdentityLocatorError.keychainFailure(status)
        }
        guard let result,
              CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw GuardianRemoteTLSIdentityLocatorError.invalidIdentityReference
        }
        return unsafeDowncast(result, to: SecIdentity.self)
    }
}
