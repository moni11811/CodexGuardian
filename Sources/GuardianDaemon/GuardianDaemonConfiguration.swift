import Foundation
import GuardianCore

struct GuardianDaemonConfiguration {
    let stateDirectory: URL
    let developmentSocketPath: String?
    let runOnce: Bool

    static func parse(arguments: [String]) throws -> GuardianDaemonConfiguration {
        var stateDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "CodexGuardian", directoryHint: .isDirectory)
        var socketPath: String?
        var runOnce = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--state-dir":
                index += 1
                guard index < arguments.count else {
                    throw GuardianDaemonServerError.invalidConfiguration
                }
                stateDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--socket":
                index += 1
                guard index < arguments.count else {
                    throw GuardianDaemonServerError.invalidConfiguration
                }
                socketPath = arguments[index]
            case "--once":
                runOnce = true
            default:
                throw GuardianDaemonServerError.invalidConfiguration
            }
            index += 1
        }
        guard stateDirectory.path.hasPrefix("/"),
              socketPath == nil || socketPath?.hasPrefix("/") == true else {
            throw GuardianDaemonServerError.invalidConfiguration
        }
        return GuardianDaemonConfiguration(
            stateDirectory: stateDirectory,
            developmentSocketPath: socketPath,
            runOnce: runOnce
        )
    }

    func prepareStateDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stateDirectory.path
        )
    }

    func registrations(at date: Date) throws -> [GuardianLocalClientRegistration] {
        let definitions: [(String, UUID, GuardianIPCClientRole, GuardianIPCCapabilities)] = [
            ("mac-ui.token", GuardianLocalClientDefaults.macUIID, .macUI,
             GuardianLocalClientDefaults.maximumCapabilities(for: .macUI)),
            ("mcp.token", GuardianLocalClientDefaults.mcpID, .mcp,
             GuardianLocalClientDefaults.maximumCapabilities(for: .mcp)),
            ("cli.token", GuardianLocalClientDefaults.cliID, .cli,
             GuardianLocalClientDefaults.maximumCapabilities(for: .cli)),
        ]
        let credentialDirectory = stateDirectory.appending(
            path: "credentials",
            directoryHint: .isDirectory
        )
        return try definitions.compactMap { filename, clientID, role, capabilities in
            let url = credentialDirectory.appending(path: filename)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let credential = try GuardianCredentialFile.load(at: url)
            return GuardianLocalClientRegistration(
                credential: credential,
                client: GuardianIPCAuthenticatedClient(
                    clientID: clientID,
                    role: role,
                    capabilities: capabilities,
                    authenticatedAt: date
                )
            )
        }
    }

    func remoteServiceConfiguration() throws -> GuardianRemoteServiceConfiguration {
        try GuardianRemoteConfigurationFile.loadIfPresent(
            at: stateDirectory.appending(path: "remote.json")
        )
    }

}
