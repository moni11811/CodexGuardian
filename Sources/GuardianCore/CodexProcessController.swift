import Foundation

public struct CodexProcessTrustRequirement: Codable, Equatable, Hashable, Sendable {
    public static let openAIProduction = CodexProcessTrustRequirement(
        bundleIdentifier: "com.openai.codex",
        signingIdentifier: "com.openai.codex",
        teamIdentifier: "2DC432GLL2"
    )

    public let bundleIdentifier: String
    public let signingIdentifier: String
    public let teamIdentifier: String

    public init(
        bundleIdentifier: String,
        signingIdentifier: String,
        teamIdentifier: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public struct CodexApplicationCandidate: Codable, Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let bundleURLPath: String
    public let signingIdentifier: String
    public let teamIdentifier: String

    public init(
        bundleIdentifier: String,
        bundleURLPath: String,
        signingIdentifier: String,
        teamIdentifier: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleURLPath = bundleURLPath
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public struct CodexRunningProcessCandidate: Codable, Equatable, Hashable, Sendable {
    public let application: CodexApplicationCandidate
    public let processID: Int32
    public let processStartIdentity: UInt64

    public init(
        application: CodexApplicationCandidate,
        processID: Int32,
        processStartIdentity: UInt64
    ) {
        self.application = application
        self.processID = processID
        self.processStartIdentity = processStartIdentity
    }
}

public enum CodexProcessSelectionError: Error, Equatable, Sendable {
    case invalidTrustRequirement
    case applicationNotFound
    case invalidApplicationIdentity
    case bundleIdentifierMismatch
    case signingIdentifierMismatch
    case teamIdentifierMismatch
    case ambiguousApplications
    case processNotFound
    case invalidProcessIdentity
    case ambiguousProcesses
    case applicationIdentityChanged
    case processEpochChanged
}

public protocol CodexProcessDiscovering: Sendable {
    func applicationCandidates(
        bundleIdentifier: String
    ) throws -> [CodexApplicationCandidate]

    func runningProcessCandidates(
        bundleIdentifier: String
    ) throws -> [CodexRunningProcessCandidate]

    func terminate(processID: Int32, force: Bool) -> Bool
    func launch(applicationPath: String) -> Bool
}

public enum CodexProcessControllerError: Error, Equatable, Sendable {
    case applicationIdentityChanged
    case terminationFailed
    case launchFailed
    case processDidNotRestart
}

public struct CodexProcessController: Sendable {
    public let requirement: CodexProcessTrustRequirement
    private let discovery: any CodexProcessDiscovering
    private let policy = CodexProcessSelectionPolicy()

    public init(
        requirement: CodexProcessTrustRequirement,
        discovery: any CodexProcessDiscovering
    ) {
        self.requirement = requirement
        self.discovery = discovery
    }

    public func resolveApplication() throws -> CodexApplicationCandidate {
        try policy.selectApplication(
            candidates: discovery.applicationCandidates(
                bundleIdentifier: requirement.bundleIdentifier
            ),
            requirement: requirement
        )
    }

    public func captureRunningProcess() throws -> CodexRunningProcessCandidate {
        guard let process = try captureRunningProcessIfPresent() else {
            throw CodexProcessSelectionError.processNotFound
        }
        return process
    }

    public func captureRunningProcessIfPresent() throws -> CodexRunningProcessCandidate? {
        let candidates = try discovery.runningProcessCandidates(
            bundleIdentifier: requirement.bundleIdentifier
        )
        guard !candidates.isEmpty else { return nil }
        return try policy.selectRunningProcess(
            candidates: candidates,
            requirement: requirement
        )
    }

    public func captureRunningProcess(
        matching application: CodexApplicationCandidate
    ) throws -> CodexRunningProcessCandidate {
        guard let process = try captureRunningProcessIfPresent(
            matching: application
        ) else {
            throw CodexProcessSelectionError.processNotFound
        }
        return process
    }

    public func captureRunningProcessIfPresent(
        matching application: CodexApplicationCandidate
    ) throws -> CodexRunningProcessCandidate? {
        guard let process = try captureRunningProcessIfPresent() else {
            return nil
        }
        guard process.application == application else {
            throw CodexProcessControllerError.applicationIdentityChanged
        }
        return process
    }

    public func terminate(
        _ captured: CodexRunningProcessCandidate,
        force: Bool
    ) throws {
        let observed = try captureRunningProcess()
        try policy.validateSignalTarget(captured: captured, observed: observed)
        guard discovery.terminate(processID: observed.processID, force: force) else {
            throw CodexProcessControllerError.terminationFailed
        }
    }

    public func launch(_ captured: CodexApplicationCandidate) throws {
        let observed = try resolveApplication()
        guard observed == captured else {
            throw CodexProcessControllerError.applicationIdentityChanged
        }
        guard discovery.launch(applicationPath: captured.bundleURLPath) else {
            throw CodexProcessControllerError.launchFailed
        }
    }

    public func verifyRestart(
        previous: CodexRunningProcessCandidate
    ) throws -> CodexRunningProcessCandidate {
        try verifyLaunch(
            application: previous.application,
            previous: previous
        )
    }

    public func verifyLaunch(
        application: CodexApplicationCandidate,
        previous: CodexRunningProcessCandidate?
    ) throws -> CodexRunningProcessCandidate {
        let current = try captureRunningProcess(matching: application)
        guard previous.map({ policy.didRestart(previous: $0, current: current) })
            ?? true else {
            throw CodexProcessControllerError.processDidNotRestart
        }
        return current
    }
}

public struct CodexProcessSelectionPolicy: Sendable {
    public init() {}

    public func selectApplication(
        candidates: [CodexApplicationCandidate],
        requirement: CodexProcessTrustRequirement
    ) throws -> CodexApplicationCandidate {
        try validate(requirement)
        guard !candidates.isEmpty else {
            throw CodexProcessSelectionError.applicationNotFound
        }
        guard candidates.allSatisfy(isValidApplication) else {
            throw CodexProcessSelectionError.invalidApplicationIdentity
        }

        let trusted = try trustedApplications(
            candidates: candidates,
            requirement: requirement
        )
        guard trusted.count == 1, let selected = trusted.first else {
            throw CodexProcessSelectionError.ambiguousApplications
        }
        return selected
    }

    public func selectRunningProcess(
        candidates: [CodexRunningProcessCandidate],
        requirement: CodexProcessTrustRequirement
    ) throws -> CodexRunningProcessCandidate {
        try validate(requirement)
        guard !candidates.isEmpty else {
            throw CodexProcessSelectionError.processNotFound
        }
        guard candidates.allSatisfy({ isValidApplication($0.application) }) else {
            throw CodexProcessSelectionError.invalidApplicationIdentity
        }
        guard candidates.allSatisfy({
            $0.processID > 0 && $0.processStartIdentity > 0
        }) else {
            throw CodexProcessSelectionError.invalidProcessIdentity
        }

        let trustedApplications = try trustedApplications(
            candidates: candidates.map(\.application),
            requirement: requirement
        )
        let trustedSet = Set(trustedApplications)
        let trustedProcesses = Set(candidates.filter {
            trustedSet.contains($0.application)
        })
        guard trustedProcesses.count == 1, let selected = trustedProcesses.first else {
            throw CodexProcessSelectionError.ambiguousProcesses
        }
        return selected
    }

    public func validateSignalTarget(
        captured: CodexRunningProcessCandidate,
        observed: CodexRunningProcessCandidate
    ) throws {
        guard isValidApplication(captured.application),
              isValidApplication(observed.application),
              captured.processID > 0,
              observed.processID > 0,
              captured.processStartIdentity > 0,
              observed.processStartIdentity > 0 else {
            throw CodexProcessSelectionError.invalidProcessIdentity
        }
        guard captured.application == observed.application else {
            throw CodexProcessSelectionError.applicationIdentityChanged
        }
        guard captured.processID == observed.processID,
              captured.processStartIdentity == observed.processStartIdentity else {
            throw CodexProcessSelectionError.processEpochChanged
        }
    }

    public func didRestart(
        previous: CodexRunningProcessCandidate,
        current: CodexRunningProcessCandidate
    ) -> Bool {
        guard previous.application == current.application,
              previous.processID > 0,
              current.processID > 0,
              previous.processStartIdentity > 0,
              current.processStartIdentity > 0 else {
            return false
        }
        return previous.processID != current.processID
            || previous.processStartIdentity != current.processStartIdentity
    }

    private func trustedApplications(
        candidates: [CodexApplicationCandidate],
        requirement: CodexProcessTrustRequirement
    ) throws -> Set<CodexApplicationCandidate> {
        let bundleMatches = candidates.filter {
            $0.bundleIdentifier == requirement.bundleIdentifier
        }
        guard !bundleMatches.isEmpty else {
            throw CodexProcessSelectionError.bundleIdentifierMismatch
        }

        let signingMatches = bundleMatches.filter {
            $0.signingIdentifier == requirement.signingIdentifier
        }
        guard !signingMatches.isEmpty else {
            throw CodexProcessSelectionError.signingIdentifierMismatch
        }

        let teamMatches = signingMatches.filter {
            $0.teamIdentifier == requirement.teamIdentifier
        }
        guard !teamMatches.isEmpty else {
            throw CodexProcessSelectionError.teamIdentifierMismatch
        }
        return Set(teamMatches)
    }

    private func validate(_ requirement: CodexProcessTrustRequirement) throws {
        guard !requirement.bundleIdentifier.isEmpty,
              !requirement.signingIdentifier.isEmpty,
              !requirement.teamIdentifier.isEmpty else {
            throw CodexProcessSelectionError.invalidTrustRequirement
        }
    }

    private func isValidApplication(_ candidate: CodexApplicationCandidate) -> Bool {
        !candidate.bundleIdentifier.isEmpty
            && candidate.bundleURLPath.hasPrefix("/")
            && !candidate.signingIdentifier.isEmpty
            && !candidate.teamIdentifier.isEmpty
    }
}
