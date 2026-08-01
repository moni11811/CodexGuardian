import Darwin
import Foundation
import GuardianClient
import GuardianCore

@main
struct GuardianCLI {
    static func main() async {
        let requestedCommand = CommandLine.arguments.dropFirst().first
        let processInspectionRequested = requestedCommand == "codex-process"
        let controlInspectionRequested = requestedCommand == "codex-control"
        do {
            if processInspectionRequested {
                try inspectCodexProcess()
                return
            }
            if controlInspectionRequested {
                try inspectCodexControl()
                return
            }
            let stateDirectory = try stateDirectory(arguments: CommandLine.arguments)
            let credential = try GuardianCredentialFile.load(
                at: stateDirectory.appending(path: "credentials/cli.token")
            )
            let transport = GuardianUnixSocketTransport(
                socketPath: stateDirectory.appending(path: "guardian.sock").path,
                expectedPeerExecutablePath: try GuardianLocalDaemonEndpoint.expectedExecutablePath()
            )
            let client = GuardianClient(
                clientID: GuardianLocalClientDefaults.cliID,
                credential: credential,
                transport: transport
            )
            let command = GuardianIPCCommand(
                protocolVersion: .current,
                rpcID: UUID(),
                operationID: UUID(),
                clientID: GuardianLocalClientDefaults.cliID,
                expectedGeneration: 0,
                deadline: Date().addingTimeInterval(5),
                originThreadID: "guardianctl",
                targetThreadID: "guardianctl",
                action: .observe,
                force: false
            )
            let reply = try await client.send(command)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(reply))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            let message: String
            if processInspectionRequested {
                message = "guardianctl: Codex process unavailable or untrusted\n"
            } else if controlInspectionRequested {
                message = "guardianctl: Codex Desktop control evidence unavailable or malformed\n"
            } else {
                message = "guardianctl: daemon unavailable or untrusted\n"
            }
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func inspectCodexProcess() throws {
        let requirement = CodexProcessTrustRequirement.openAIProduction
        let controller = CodexProcessController(
            requirement: requirement,
            discovery: MacCodexProcessDiscovery()
        )
        let report = CodexProcessInspectionReport(
            capturedAt: Date(),
            requirement: requirement,
            application: try controller.resolveApplication(),
            runningProcess: try controller.captureRunningProcessIfPresent()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func inspectCodexControl() throws {
        let controller = CodexProcessController(
            requirement: .openAIProduction,
            discovery: MacCodexProcessDiscovery()
        )
        let desktop = try controller.captureRunningProcess()
        let processData = try ProcessOutputCapture(maximumBytes: 2_000_000).run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ww", "-axo", "pid=,ppid=,command="]
        )
        guard let processList = String(data: processData, encoding: .utf8) else {
            throw GuardianCLIError.invalidProcessOutput
        }
        let observation = try CodexDesktopProcessProbe().inspect(
            processList: processList,
            desktop: desktop
        )
        let revalidatedDesktop = try controller.captureRunningProcess()
        try CodexProcessSelectionPolicy().validateSignalTarget(
            captured: desktop,
            observed: revalidatedDesktop
        )
        let evidence = CodexDesktopControlEvidence(
            desktopProcessID: desktop.processID,
            appServerProcessID: observation.processID,
            appServerParentProcessID: observation.parentProcessID,
            transport: observation.transport,
            socketOwnerProcessID: nil,
            schemaSupported: false,
            inventory: .unavailable,
            desktopUISynchronizationProven: false,
            correlatedMessagePersistenceProven: false
        )
        let report = CodexDesktopControlInspectionReport(
            capturedAt: Date(),
            desktopProcessID: desktop.processID,
            desktopProcessStartIdentity: desktop.processStartIdentity,
            appServerProcessID: observation.processID,
            appServerParentProcessID: observation.parentProcessID,
            transport: observation.transport.reportName,
            listenerAddress: observation.listenerURL == nil ? nil : "<redacted>",
            controlMode: CodexDesktopControlPolicy().mode(for: evidence).reportName,
            inventory: "unavailable",
            desktopUISynchronizationProven: false,
            correlatedMessagePersistenceProven: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func stateDirectory(arguments: [String]) throws -> URL {
        if let index = arguments.firstIndex(of: "--state-dir"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            guard path.hasPrefix("/") else { throw GuardianCLIError.invalidConfiguration }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "CodexGuardian", directoryHint: .isDirectory)
    }

}

private struct CodexProcessInspectionReport: Encodable {
    let capturedAt: Date
    let requirement: CodexProcessTrustRequirement
    let application: CodexApplicationCandidate
    let runningProcess: CodexRunningProcessCandidate?
}

private struct CodexDesktopControlInspectionReport: Encodable {
    let capturedAt: Date
    let desktopProcessID: Int32
    let desktopProcessStartIdentity: UInt64
    let appServerProcessID: Int32
    let appServerParentProcessID: Int32
    let transport: String
    let listenerAddress: String?
    let controlMode: String
    let inventory: String
    let desktopUISynchronizationProven: Bool
    let correlatedMessagePersistenceProven: Bool
}

private extension CodexDesktopControlEvidence.Transport {
    var reportName: String {
        switch self {
        case .stdio: "stdio"
        case .unixSocket: "unixSocket"
        case .unknown: "unknown"
        }
    }
}

private extension CodexDesktopControlMode {
    var reportName: String {
        switch self {
        case .unavailable(let reason): "unavailable:\(reason.reportName)"
        case .observeOnly: "observeOnly"
        case .readWrite: "readWrite"
        }
    }
}

private extension CodexDesktopControlUnavailableReason {
    var reportName: String {
        switch self {
        case .appServerMissing: "appServerMissing"
        case .appServerIsNotDesktopChild: "appServerIsNotDesktopChild"
        case .noSupportedControlListener: "noSupportedControlListener"
        case .socketOwnerMismatch: "socketOwnerMismatch"
        case .unsupportedSchema: "unsupportedSchema"
        }
    }
}

private enum GuardianCLIError: Error {
    case invalidConfiguration
    case invalidProcessOutput
}
