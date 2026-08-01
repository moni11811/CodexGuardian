import Foundation
import Testing
@testable import GuardianCore

@Test func trustedCodexCandidateResolvesItsBundledAppServerExecutable() throws {
    let fixture = try appServerExecutableFixture(permissions: 0o700)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let executableURL = try CodexAppServerExecutablePolicy().executableURL(
        for: fixture.application
    )

    #expect(executableURL == fixture.executableURL.resolvingSymlinksInPath())
}

@Test func appServerExecutableSymlinkCannotEscapeTrustedBundle() throws {
    let fixture = try appServerExecutableFixture(permissions: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let escapeDirectory = fixture.root.appending(
        path: "Trusted.app-escape",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: escapeDirectory,
        withIntermediateDirectories: true
    )
    let escapedExecutableURL = escapeDirectory.appending(path: "codex")
    try writeExecutable(at: escapedExecutableURL, permissions: 0o700)
    try FileManager.default.createSymbolicLink(
        at: fixture.executableURL,
        withDestinationURL: escapedExecutableURL
    )

    #expect(throws: CodexAppServerExecutablePolicyError.executableEscapesBundle) {
        try CodexAppServerExecutablePolicy().executableURL(for: fixture.application)
    }
}

@Test func nonExecutableBundledAppServerFailsClosed() throws {
    let fixture = try appServerExecutableFixture(permissions: 0o600)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(throws: CodexAppServerExecutablePolicyError.executableUnavailable) {
        try CodexAppServerExecutablePolicy().executableURL(for: fixture.application)
    }
}

private struct AppServerExecutableFixture {
    let root: URL
    let application: CodexApplicationCandidate
    let executableURL: URL
}

private func appServerExecutableFixture(
    permissions: Int?
) throws -> AppServerExecutableFixture {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "guardian-app-server-executable-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let bundleURL = root.appending(
        path: "Trusted.app",
        directoryHint: .isDirectory
    )
    let resourcesURL = bundleURL.appending(
        path: "Contents/Resources",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: resourcesURL,
        withIntermediateDirectories: true
    )
    let executableURL = resourcesURL.appending(path: "codex")
    if let permissions {
        try writeExecutable(at: executableURL, permissions: permissions)
    }
    return AppServerExecutableFixture(
        root: root,
        application: CodexApplicationCandidate(
            bundleIdentifier: "com.openai.codex",
            bundleURLPath: bundleURL.path,
            signingIdentifier: "com.openai.codex",
            teamIdentifier: "2DC432GLL2"
        ),
        executableURL: executableURL
    )
}

private func writeExecutable(at url: URL, permissions: Int) throws {
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: url.path
    )
}
