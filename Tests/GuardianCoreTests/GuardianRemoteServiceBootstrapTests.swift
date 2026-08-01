import Foundation
import GuardianCore
import Security
import Testing

@Test func disabledRemoteBootstrapTouchesNoIdentityOrListener() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-remote-bootstrap-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let runtime = try GuardianDaemonRuntime.start(
        journal: journal,
        registeredClients: [],
        mode: .shadowOnly,
        at: Date(timeIntervalSince1970: 100)
    )
    let calls = GuardianBootstrapCallCounter()

    let server = try GuardianRemoteServiceBootstrap().make(
        configuration: .disabled,
        journal: journal,
        runtime: runtime,
        identityLoader: { _ in
            calls.increment()
            throw GuardianRemoteTLSIdentityLocatorError.identityNotFound
        },
        listenerFactory: { _, _ in
            calls.increment()
            return nil
        }
    )

    #expect(server == nil)
    #expect(calls.value == 0)
}

private final class GuardianBootstrapCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
