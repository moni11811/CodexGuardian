import Foundation
import GuardianCore
import Testing

@Test func missingRemoteConfigurationDefaultsToDisabled() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-config-missing-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configuration = try GuardianRemoteConfigurationFile.loadIfPresent(
        at: directory.appending(path: "remote.json")
    )

    #expect(configuration == .disabled)
}

@Test func readableRemoteConfigurationIsRejectedBeforeDecode() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-config-readable-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "remote.json")
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: url.path
    )

    #expect(throws: GuardianRemoteConfigurationFileError.untrustedFile) {
        try GuardianRemoteConfigurationFile.loadIfPresent(at: url)
    }
}

@Test func enabledRemoteConfigurationRequiresPinnedIdentityAndValidPolicy() {
    let invalid = GuardianRemoteServiceConfiguration(
        listener: GuardianRemoteListenerConfiguration(
            isEnabled: true,
            bindScope: .privateNetwork,
            bindAddress: "192.168.1.20",
            port: 47_411,
            transport: .tls13(serverIdentityHash: Data(repeating: 0xA1, count: 32)),
            securityReviewEvidenceID: "phase7-threat-model"
        ),
        identityLabel: nil,
        rateLimitPolicy: .productionDefault
    )

    #expect(invalid.validation == .rejected(.identityLabelRequired))
}
