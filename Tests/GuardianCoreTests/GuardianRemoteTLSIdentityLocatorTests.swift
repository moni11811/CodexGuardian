import Foundation
import GuardianCore
import Security
import Testing

@Test func remoteTLSIdentityLookupIsExactAndMissingIdentityFailsClosed() {
    let recorder = GuardianSecurityQueryRecorder()
    let locator = GuardianRemoteTLSIdentityLocator(query: { query, _ in
        recorder.record(query)
        return errSecItemNotFound
    })

    #expect(throws: GuardianRemoteTLSIdentityLocatorError.identityNotFound) {
        try locator.load(label: "com.moni.codexguardian.remote-tls")
    }

    let query = recorder.query as NSDictionary?
    #expect(query?[kSecClass as String] as? String == kSecClassIdentity as String)
    #expect(query?[kSecAttrLabel as String] as? String
        == "com.moni.codexguardian.remote-tls")
    #expect(query?[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    #expect(query?[kSecReturnRef as String] as? Bool == true)
}

private final class GuardianSecurityQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CFDictionary?

    var query: CFDictionary? { lock.withLock { stored } }

    func record(_ query: CFDictionary) {
        lock.withLock { stored = query }
    }
}
