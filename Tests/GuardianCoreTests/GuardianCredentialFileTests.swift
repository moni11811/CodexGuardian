import Darwin
import Foundation
import GuardianCore
import Testing

@Test func credentialLoaderRejectsWrongLengthAndWeakPermissions() throws {
    let root = try temporaryCredentialDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let credential = root.appending(path: "client.token")
    try Data(repeating: 0xA5, count: 31).write(to: credential)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: credential.path
    )
    #expect(throws: GuardianCredentialFileError.invalidLength) {
        try GuardianCredentialFile.load(at: credential)
    }

    try Data(repeating: 0xA5, count: 32).write(to: credential)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: credential.path
    )
    #expect(throws: GuardianCredentialFileError.untrustedFile) {
        try GuardianCredentialFile.load(at: credential)
    }
}

@Test func credentialLoaderRejectsSymlinkAndLoadsPrivateRegularFile() throws {
    let root = try temporaryCredentialDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let credential = root.appending(path: "client.token")
    let link = root.appending(path: "redirect.token")
    let expected = Data(repeating: 0x3C, count: 32)
    try expected.write(to: credential)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: credential.path
    )
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: credential)

    #expect(throws: GuardianCredentialFileError.untrustedFile) {
        try GuardianCredentialFile.load(at: link)
    }
    #expect(try GuardianCredentialFile.load(at: credential) == expected)
}

private func temporaryCredentialDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "guardian-credential-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: root.path
    )
    return root
}
