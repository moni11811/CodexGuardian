import Foundation

public enum CodexDesktopProcessProbeError: Error, Equatable, Sendable {
    case malformedProcessTable
    case appServerMissing
    case ambiguousAppServers
    case conflictingTransportArguments
    case invalidTransportArguments
}

public struct CodexDesktopAppServerObservation: Equatable, Sendable {
    public let processID: Int32
    public let parentProcessID: Int32
    public let transport: CodexDesktopControlEvidence.Transport
    public let listenerURL: String?

    public init(
        processID: Int32,
        parentProcessID: Int32,
        transport: CodexDesktopControlEvidence.Transport,
        listenerURL: String?
    ) {
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.transport = transport
        self.listenerURL = listenerURL
    }
}

public struct CodexDesktopProcessProbe: Sendable {
    public init() {}

    public func inspect(
        processList: String,
        desktop: CodexRunningProcessCandidate
    ) throws -> CodexDesktopAppServerObservation {
        let executablePath = desktop.application.bundleURLPath
            + "/Contents/Resources/codex"
        var matches: [CodexDesktopAppServerObservation] = []

        for rawLine in processList.split(whereSeparator: \ .isNewline) {
            let fields = rawLine.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \ .isWhitespace
            )
            guard fields.count == 3,
                  let processID = Int32(fields[0]),
                  processID > 0,
                  let parentProcessID = Int32(fields[1]),
                  parentProcessID >= 0 else {
                throw CodexDesktopProcessProbeError.malformedProcessTable
            }

            let command = String(fields[2])
            guard parentProcessID == desktop.processID,
                  command == executablePath || command.hasPrefix(executablePath + " ") else {
                continue
            }

            let suffix = command.dropFirst(executablePath.count)
            let arguments = suffix.split(whereSeparator: \ .isWhitespace).map(String.init)
            guard let appServerIndex = appServerCommandIndex(in: arguments) else {
                continue
            }

            let appServerArguments = Array(arguments.dropFirst(appServerIndex + 1))
            if let first = appServerArguments.first,
               first == "proxy" || first == "daemon" || first.hasPrefix("generate-") {
                continue
            }

            let transport = try parseTransport(arguments: appServerArguments)
            matches.append(
                CodexDesktopAppServerObservation(
                    processID: processID,
                    parentProcessID: parentProcessID,
                    transport: transport.kind,
                    listenerURL: transport.listenerURL
                )
            )
        }

        guard !matches.isEmpty else {
            throw CodexDesktopProcessProbeError.appServerMissing
        }
        guard matches.count == 1 else {
            throw CodexDesktopProcessProbeError.ambiguousAppServers
        }
        return matches[0]
    }

    private func appServerCommandIndex(in arguments: [String]) -> Int? {
        let valueOptions: Set<String> = [
            "-c", "--config", "--enable", "--disable", "--remote",
            "--remote-auth-token-env", "-i", "--image", "-m", "--model",
            "--local-provider", "-p", "--profile", "-s", "--sandbox",
            "-C", "--cd", "--add-dir", "-a", "--ask-for-approval"
        ]
        let flagOptions: Set<String> = [
            "--strict-config", "--oss",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust", "--search", "--no-alt-screen",
            "-h", "--help", "-V", "--version"
        ]
        let valueOptionPrefixes = valueOptions
            .filter { $0.hasPrefix("--") }
            .map { $0 + "=" }
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "app-server" {
                return index
            }
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                index += 2
                continue
            }
            if valueOptionPrefixes.contains(where: argument.hasPrefix)
                || flagOptions.contains(argument) {
                index += 1
                continue
            }
            return nil
        }
        return nil
    }

    private func parseTransport(
        arguments: [String]
    ) throws -> (kind: CodexDesktopControlEvidence.Transport, listenerURL: String?) {
        var usesStdio = false
        var listeners: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--stdio" {
                usesStdio = true
            } else if argument == "--listen" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count,
                      !arguments[valueIndex].hasPrefix("--") else {
                    throw CodexDesktopProcessProbeError.invalidTransportArguments
                }
                listeners.append(arguments[valueIndex])
                index = valueIndex
            } else if argument.hasPrefix("--listen=") {
                let value = String(argument.dropFirst("--listen=".count))
                guard !value.isEmpty else {
                    throw CodexDesktopProcessProbeError.invalidTransportArguments
                }
                listeners.append(value)
            }
            index += 1
        }

        guard listeners.count <= 1 else {
            throw CodexDesktopProcessProbeError.conflictingTransportArguments
        }
        guard !(usesStdio && !listeners.isEmpty) else {
            throw CodexDesktopProcessProbeError.conflictingTransportArguments
        }

        if usesStdio || listeners.isEmpty {
            return (.stdio, nil)
        }

        let listenerURL = listeners[0]
        if listenerURL == "stdio://" {
            return (.stdio, listenerURL)
        }
        if listenerURL.hasPrefix("unix://") {
            return (.unixSocket, listenerURL)
        }
        return (.unknown, listenerURL)
    }
}
