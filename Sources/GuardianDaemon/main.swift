import Darwin
import Foundation
import GuardianCore

do {
    let configuration = try GuardianDaemonConfiguration.parse(
        arguments: CommandLine.arguments
    )
    try configuration.prepareStateDirectory()
    let now = Date()
    let registrations = try configuration.registrations(at: now)
    guard !registrations.isEmpty else {
        throw GuardianDaemonServerError.invalidConfiguration
    }
    let journal = try GuardianJournal(
        databaseURL: configuration.stateDirectory.appending(path: "guardian.sqlite")
    )
    let runtime = try GuardianDaemonRuntime.start(
        journal: journal,
        registeredClients: registrations,
        mode: .shadowOnly,
        at: now
    )
    var remoteServer: GuardianRemoteTLSConnectionServer?
    do {
        remoteServer = try GuardianRemoteServiceBootstrap().make(
            configuration: configuration.remoteServiceConfiguration(),
            journal: journal,
            runtime: runtime
        )
        try remoteServer?.start()
    } catch {
        FileHandle.standardError.write(
            Data("guardian-daemon: optional remote service unavailable\n".utf8)
        )
        remoteServer = nil
    }
    defer { remoteServer?.cancel() }
    let listeningDescriptor: Int32
    if let socketPath = configuration.developmentSocketPath {
        listeningDescriptor = try GuardianDaemonBootstrap.developmentSocket(path: socketPath)
    } else {
        listeningDescriptor = try GuardianDaemonBootstrap.launchdSocket(named: "GuardianSocket")
    }
    defer { Darwin.close(listeningDescriptor) }
    try GuardianDaemonServer(
        listeningDescriptor: listeningDescriptor,
        runtime: runtime,
        runOnce: configuration.runOnce
    ).run()
} catch {
    FileHandle.standardError.write(Data("guardian-daemon: startup or request failure\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
