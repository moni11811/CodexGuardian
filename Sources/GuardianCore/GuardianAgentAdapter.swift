public enum GuardianAgentCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case observe
    case prompt
    case steer
    case interrupt
    case approve
    case deny
    case repair
    case hardRecover
    case cancelRecovery
    case readFiles
    case openTerminal

    public var changesAgentState: Bool {
        switch self {
        case .observe, .readFiles:
            return false
        case .prompt, .steer, .interrupt, .approve, .deny, .repair,
             .hardRecover, .cancelRecovery, .openTerminal:
            return true
        }
    }
}

public enum GuardianAgentAdapterTransport: String, Codable, Equatable, Sendable {
    case semanticACP
    case ptyHeuristic
}

public struct GuardianAgentAdapterManifest: Codable, Equatable, Sendable {
    public let identity: GuardianAdapterIdentity
    public let transport: GuardianAgentAdapterTransport
    public let declaredCapabilities: Set<GuardianAgentCapability>

    public init(
        identity: GuardianAdapterIdentity,
        transport: GuardianAgentAdapterTransport,
        declaredCapabilities: Set<GuardianAgentCapability>
    ) {
        self.identity = identity
        self.transport = transport
        self.declaredCapabilities = declaredCapabilities
    }

    public var effectiveCapabilities: Set<GuardianAgentCapability> {
        switch transport {
        case .semanticACP:
            return declaredCapabilities
        case .ptyHeuristic:
            return declaredCapabilities.intersection([.observe])
        }
    }

    public var canProvideDestructiveAuthority: Bool {
        transport == .semanticACP
            && effectiveCapabilities.contains(where: \.changesAgentState)
    }

    public var isValid: Bool {
        identity.isValid && declaredCapabilities.count <= GuardianAgentCapability.allCases.count
    }
}

public struct GuardianAgentProcessIdentity: Codable, Equatable, Sendable {
    public let processID: Int32
    public let processStartIdentity: UInt64

    public init(processID: Int32, processStartIdentity: UInt64) {
        self.processID = processID
        self.processStartIdentity = processStartIdentity
    }

    public var isValid: Bool {
        processID > 0 && processStartIdentity > 0
    }
}

public struct GuardianAgentResourceOwnership: Codable, Equatable, Sendable {
    public let taskID: String
    public let canonicalWorktreePath: String
    public let process: GuardianAgentProcessIdentity

    public init(
        taskID: String,
        canonicalWorktreePath: String,
        process: GuardianAgentProcessIdentity
    ) {
        self.taskID = taskID
        self.canonicalWorktreePath = canonicalWorktreePath
        self.process = process
    }

    public var isValid: Bool {
        !taskID.isEmpty
            && taskID.utf8.count <= 512
            && canonicalWorktreePath.utf8.count <= 4_096
            && canonicalWorktreePath.first == "/"
            && canonicalWorktreePath.split(separator: "/").allSatisfy {
                $0 != "." && $0 != ".."
            }
            && process.isValid
    }
}

public struct GuardianAgentActionRequest: Codable, Equatable, Sendable {
    public let capability: GuardianAgentCapability
    public let target: GuardianAgentResourceOwnership

    public init(
        capability: GuardianAgentCapability,
        target: GuardianAgentResourceOwnership
    ) {
        self.capability = capability
        self.target = target
    }
}

public enum GuardianAgentActionAuthority: Codable, Equatable, Sendable {
    case observationOnly
    case semanticAuthority
}

public enum GuardianAgentActionDenial: Codable, Equatable, Sendable {
    case invalidAdapterManifest
    case invalidOwnership
    case unsupportedCapability(GuardianAgentCapability)
    case heuristicObserveOnly
    case taskOwnershipMismatch
    case worktreeOwnershipMismatch
    case processOwnershipMismatch
}

public enum GuardianAgentActionDecision: Codable, Equatable, Sendable {
    case allowed(GuardianAgentActionAuthority)
    case denied(GuardianAgentActionDenial)
}

public struct GuardianAgentAdapterPolicy: Sendable {
    public init() {}

    public func evaluate(
        _ request: GuardianAgentActionRequest,
        adapter: GuardianAgentAdapterManifest,
        ownership: GuardianAgentResourceOwnership
    ) -> GuardianAgentActionDecision {
        guard adapter.isValid else {
            return .denied(.invalidAdapterManifest)
        }
        guard request.target.isValid, ownership.isValid else {
            return .denied(.invalidOwnership)
        }
        if adapter.transport == .ptyHeuristic, request.capability != .observe {
            return .denied(.heuristicObserveOnly)
        }
        guard adapter.effectiveCapabilities.contains(request.capability) else {
            return .denied(.unsupportedCapability(request.capability))
        }
        guard request.target.taskID == ownership.taskID else {
            return .denied(.taskOwnershipMismatch)
        }
        guard request.target.canonicalWorktreePath == ownership.canonicalWorktreePath else {
            return .denied(.worktreeOwnershipMismatch)
        }
        guard request.target.process == ownership.process else {
            return .denied(.processOwnershipMismatch)
        }

        switch adapter.transport {
        case .semanticACP:
            return .allowed(.semanticAuthority)
        case .ptyHeuristic:
            return .allowed(.observationOnly)
        }
    }
}
