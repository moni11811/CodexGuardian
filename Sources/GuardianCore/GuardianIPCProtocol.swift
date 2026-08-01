import Foundation

public struct GuardianIPCProtocolVersion: Codable, Equatable, Hashable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let current = GuardianIPCProtocolVersion(major: 1, minor: 2)
}

public enum GuardianIPCClientRole: String, Codable, Equatable, Sendable {
    case macUI
    case mcp
    case cli
    case remoteGateway
}

public struct GuardianIPCCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let observe = GuardianIPCCapabilities(rawValue: 1 << 0)
    public static let nativeRecovery = GuardianIPCCapabilities(rawValue: 1 << 1)
    public static let hardRecovery = GuardianIPCCapabilities(rawValue: 1 << 2)
    public static let crossThreadControl = GuardianIPCCapabilities(rawValue: 1 << 3)
    public static let forceRestart = GuardianIPCCapabilities(rawValue: 1 << 4)
}

public struct GuardianIPCAuthenticatedClient: Codable, Equatable, Sendable {
    public let clientID: UUID
    public let role: GuardianIPCClientRole
    public let capabilities: GuardianIPCCapabilities
    public let authenticatedAt: Date

    public init(
        clientID: UUID,
        role: GuardianIPCClientRole,
        capabilities: GuardianIPCCapabilities,
        authenticatedAt: Date
    ) {
        self.clientID = clientID
        self.role = role
        self.capabilities = capabilities
        self.authenticatedAt = authenticatedAt
    }
}

public enum GuardianIPCCommandAction: String, Codable, Equatable, Sendable {
    case observe
    case recover
    case hardRecover
    case cancelRecovery
}

public struct GuardianIPCCommand: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianIPCProtocolVersion
    public let rpcID: UUID
    public let operationID: UUID
    public let clientID: UUID
    public let expectedGeneration: Int64
    public let deadline: Date
    public let originThreadID: String
    public let targetThreadID: String
    public let action: GuardianIPCCommandAction
    public let force: Bool

    public init(
        protocolVersion: GuardianIPCProtocolVersion,
        rpcID: UUID,
        operationID: UUID,
        clientID: UUID,
        expectedGeneration: Int64,
        deadline: Date,
        originThreadID: String,
        targetThreadID: String,
        action: GuardianIPCCommandAction,
        force: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.rpcID = rpcID
        self.operationID = operationID
        self.clientID = clientID
        self.expectedGeneration = expectedGeneration
        self.deadline = deadline
        self.originThreadID = originThreadID
        self.targetThreadID = targetThreadID
        self.action = action
        self.force = force
    }
}

public enum GuardianIPCCommandRejection: Codable, Equatable, Sendable {
    case unsupportedProtocol(GuardianIPCProtocolVersion)
    case clientIdentityMismatch
    case staleGeneration(expected: Int64, current: Int64)
    case commandExpired
    case missingCapability(GuardianIPCCapabilities)
    case roleCannotControlOtherThread(GuardianIPCClientRole)
    case roleCannotForce(GuardianIPCClientRole)
    case invalidThreadBinding
}

public enum GuardianIPCCommandValidation: Codable, Equatable, Sendable {
    case success
    case failure(GuardianIPCCommandRejection)
}

public struct GuardianIPCCommandValidator: Sendable {
    public init() {}

    public func validate(
        _ command: GuardianIPCCommand,
        from client: GuardianIPCAuthenticatedClient,
        currentGeneration: Int64,
        now: Date
    ) -> GuardianIPCCommandValidation {
        guard command.protocolVersion == .current else {
            return .failure(.unsupportedProtocol(command.protocolVersion))
        }
        guard command.clientID == client.clientID else {
            return .failure(.clientIdentityMismatch)
        }
        let generationMatches = command.expectedGeneration == currentGeneration
            || (command.action == .observe && command.expectedGeneration == 0)
        guard generationMatches else {
            return .failure(.staleGeneration(
                expected: command.expectedGeneration,
                current: currentGeneration
            ))
        }
        guard command.deadline > now else {
            return .failure(.commandExpired)
        }
        guard !command.originThreadID.isEmpty, !command.targetThreadID.isEmpty else {
            return .failure(.invalidThreadBinding)
        }

        let required = requiredCapability(for: command.action)
        guard client.capabilities.contains(required) else {
            return .failure(.missingCapability(required))
        }
        if client.role == .mcp, command.targetThreadID != command.originThreadID {
            return .failure(.roleCannotControlOtherThread(.mcp))
        }
        if client.role == .mcp, command.force {
            return .failure(.roleCannotForce(.mcp))
        }
        if command.targetThreadID != command.originThreadID,
           !client.capabilities.contains(.crossThreadControl) {
            return .failure(.missingCapability(.crossThreadControl))
        }
        if command.force, !client.capabilities.contains(.forceRestart) {
            return .failure(.missingCapability(.forceRestart))
        }
        return .success
    }

    private func requiredCapability(
        for action: GuardianIPCCommandAction
    ) -> GuardianIPCCapabilities {
        switch action {
        case .observe:
            return .observe
        case .recover, .cancelRecovery:
            return .nativeRecovery
        case .hardRecover:
            return .hardRecovery
        }
    }
}

public struct GuardianIPCEventCursor: Codable, Equatable, Sendable {
    public let generation: Int64
    public let lastSequence: Int64

    public init(generation: Int64, lastSequence: Int64) {
        self.generation = generation
        self.lastSequence = lastSequence
    }
}

public enum GuardianIPCEventKind: String, Codable, Equatable, Sendable {
    case operationChanged
    case taskChanged
    case daemonGenerationChanged
}

public struct GuardianIPCEvent: Codable, Equatable, Sendable {
    public let generation: Int64
    public let sequence: Int64
    public let operationID: UUID?
    public let emittedAt: Date
    public let kind: GuardianIPCEventKind

    public init(
        generation: Int64,
        sequence: Int64,
        operationID: UUID?,
        emittedAt: Date,
        kind: GuardianIPCEventKind
    ) {
        self.generation = generation
        self.sequence = sequence
        self.operationID = operationID
        self.emittedAt = emittedAt
        self.kind = kind
    }
}

public enum GuardianIPCSnapshotReason: Equatable, Sendable {
    case generationChanged(expected: Int64, received: Int64)
    case sequenceGap(expected: Int64, received: Int64)
}

public enum GuardianIPCEventAssessment: Equatable, Sendable {
    case accepted
    case snapshotRequired(GuardianIPCSnapshotReason)
}

public enum GuardianIPCEventValidator {
    public static func assess(
        _ event: GuardianIPCEvent,
        after cursor: GuardianIPCEventCursor
    ) -> GuardianIPCEventAssessment {
        guard event.generation == cursor.generation else {
            return .snapshotRequired(.generationChanged(
                expected: cursor.generation,
                received: event.generation
            ))
        }
        let expected = cursor.lastSequence + 1
        guard event.sequence == expected else {
            return .snapshotRequired(.sequenceGap(
                expected: expected,
                received: event.sequence
            ))
        }
        return .accepted
    }
}

public enum GuardianDaemonEventReplay: Equatable, Sendable {
    case events([GuardianIPCEvent], nextCursor: GuardianIPCEventCursor)
    case snapshotRequired(GuardianIPCSnapshotReason)
}

public struct GuardianIPCOperationSnapshot: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let originThreadID: String
    public let phase: String
    public let readiness: GuardianReadinessDecision?

    public init(
        operationID: UUID,
        originThreadID: String,
        phase: String,
        readiness: GuardianReadinessDecision? = nil
    ) {
        self.operationID = operationID
        self.originThreadID = originThreadID
        self.phase = phase
        self.readiness = readiness
    }
}

public struct GuardianIPCOperationHistoryItem: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let kind: GuardianOperationKind
    public let originThreadID: String
    public let phase: GuardianOperationPhase
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        operationID: UUID,
        kind: GuardianOperationKind,
        originThreadID: String,
        phase: GuardianOperationPhase,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.operationID = operationID
        self.kind = kind
        self.originThreadID = originThreadID
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        !originThreadID.isEmpty
            && originThreadID.utf8.count <= 1_024
            && createdAt.timeIntervalSince1970.isFinite
            && updatedAt.timeIntervalSince1970.isFinite
            && updatedAt >= createdAt
    }
}

public enum GuardianIPCOperationHistoryCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case truncated
}

public struct GuardianIPCOperationHistoryPage: Codable, Equatable, Sendable {
    public static let maximumItems = 100

    public let items: [GuardianIPCOperationHistoryItem]
    public let totalCount: Int
    public let completeness: GuardianIPCOperationHistoryCompleteness

    public init(
        items: [GuardianIPCOperationHistoryItem],
        totalCount: Int,
        completeness: GuardianIPCOperationHistoryCompleteness
    ) {
        self.items = items
        self.totalCount = totalCount
        self.completeness = completeness
    }

    public var isValid: Bool {
        totalCount >= items.count
            && items.count <= Self.maximumItems
            && Set(items.map(\.operationID)).count == items.count
            && items.allSatisfy(\.isValid)
            && (completeness == .complete
                ? totalCount == items.count
                : totalCount > items.count)
    }
}

public struct GuardianIPCTaskSnapshot: Codable, Equatable, Sendable {
    public let threadID: String
    public let state: AuthoritativeTaskState
    public let reason: TaskStateClassificationReason
    public let serverGeneration: Int64
    public let eventSequence: Int64
    public let confidence: Double
    public let expiresAt: Date

    public init(
        threadID: String,
        state: AuthoritativeTaskState,
        reason: TaskStateClassificationReason,
        serverGeneration: Int64,
        eventSequence: Int64,
        confidence: Double,
        expiresAt: Date
    ) {
        self.threadID = threadID
        self.state = state
        self.reason = reason
        self.serverGeneration = serverGeneration
        self.eventSequence = eventSequence
        self.confidence = confidence
        self.expiresAt = expiresAt
    }
}

public struct GuardianIPCFullSnapshot: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianIPCProtocolVersion
    public let generation: Int64
    public let lastSequence: Int64
    public let capturedAt: Date
    public let operations: [GuardianIPCOperationSnapshot]
    public let operationHistory: GuardianIPCOperationHistoryPage?
    public let tasks: [GuardianIPCTaskSnapshot]
    public let taskInventoryCompleteness: TaskInventoryCompleteness

    public init(
        protocolVersion: GuardianIPCProtocolVersion,
        generation: Int64,
        lastSequence: Int64,
        capturedAt: Date,
        operations: [GuardianIPCOperationSnapshot],
        operationHistory: GuardianIPCOperationHistoryPage? = nil,
        tasks: [GuardianIPCTaskSnapshot] = [],
        taskInventoryCompleteness: TaskInventoryCompleteness = .incomplete
    ) {
        self.protocolVersion = protocolVersion
        self.generation = generation
        self.lastSequence = lastSequence
        self.capturedAt = capturedAt
        self.operations = operations
        self.operationHistory = operationHistory
        self.tasks = tasks
        self.taskInventoryCompleteness = taskInventoryCompleteness
    }

    public var cursor: GuardianIPCEventCursor {
        GuardianIPCEventCursor(generation: generation, lastSequence: lastSequence)
    }
}

public enum GuardianIPCRPCExpiryReason: String, Codable, Equatable, Sendable {
    case clientDisconnected
    case deadlineExceeded
}

public enum GuardianIPCRPCState: Codable, Equatable, Sendable {
    case open
    case completed
    case expired(reason: GuardianIPCRPCExpiryReason, at: Date)
}

public struct GuardianIPCInFlightRPC: Codable, Equatable, Sendable {
    public let rpcID: UUID
    public let operationID: UUID
    public let clientID: UUID
    public let deadline: Date
    public let state: GuardianIPCRPCState

    public init(
        rpcID: UUID,
        operationID: UUID,
        clientID: UUID,
        deadline: Date,
        state: GuardianIPCRPCState
    ) {
        self.rpcID = rpcID
        self.operationID = operationID
        self.clientID = clientID
        self.deadline = deadline
        self.state = state
    }

    func expiring(at date: Date) -> GuardianIPCInFlightRPC {
        GuardianIPCInFlightRPC(
            rpcID: rpcID,
            operationID: operationID,
            clientID: clientID,
            deadline: deadline,
            state: .expired(reason: .clientDisconnected, at: date)
        )
    }
}

public enum GuardianIPCDisconnectReducer {
    public static func expireOpenRPCs(
        ownedBy clientID: UUID,
        at date: Date,
        in requests: [GuardianIPCInFlightRPC]
    ) -> [GuardianIPCInFlightRPC] {
        let matching = requests.compactMap { request -> GuardianIPCInFlightRPC? in
            guard request.clientID == clientID, request.state == .open else { return nil }
            return request.expiring(at: date)
        }.sorted { $0.rpcID.uuidString < $1.rpcID.uuidString }
        let untouched = requests.filter {
            !($0.clientID == clientID && $0.state == .open)
        }
        return matching + untouched
    }
}
