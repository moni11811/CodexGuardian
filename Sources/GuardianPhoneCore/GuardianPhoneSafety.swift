import Foundation

public struct OperationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var isValid: Bool {
        !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rawValue.utf8.count <= 512
    }
}

public struct PhoneCommandTarget: Codable, Equatable, Hashable, Sendable {
    public let threadID: String
    public let serverGeneration: Int64

    public init(threadID: String, serverGeneration: Int64) {
        self.threadID = threadID
        self.serverGeneration = serverGeneration
    }

    public var isValid: Bool {
        let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 1_024 && serverGeneration > 0
    }
}

public enum PhoneAction: String, Codable, Equatable, Hashable, Sendable {
    case observe
    case promptAgent
    case steerAgent
    case interruptAgent
    case approve
    case deny
    case repair
    case restartAgent
    case cancelRecovery
    case readFiles

    public var isDestructive: Bool {
        switch self {
        case .restartAgent:
            true
        case .observe, .promptAgent, .steerAgent, .interruptAgent, .approve,
             .deny, .repair, .cancelRecovery, .readFiles:
            false
        }
    }
}

public enum PhoneCommandState: Codable, Equatable, Sendable {
    case pending
    case accepted
    case applied(at: Date)
    case failed(code: String, at: Date)
    case indeterminate(code: String, at: Date)
}

public enum PhoneCommandPresentation: String, Codable, Equatable, Sendable {
    case waitingForGuardian
    case acceptedByGuardian
    case applied
    case failed
    case needsReview
}

public struct PhoneCommandRecord: Codable, Equatable, Sendable {
    public let id: OperationID
    public let action: PhoneAction
    public let state: PhoneCommandState
    public let createdAt: Date

    public init(
        id: OperationID,
        action: PhoneAction,
        state: PhoneCommandState,
        createdAt: Date
    ) {
        self.id = id
        self.action = action
        self.state = state
        self.createdAt = createdAt
    }

    public var isApplied: Bool {
        if case .applied = state { return true }
        return false
    }

    public var presentation: PhoneCommandPresentation {
        switch state {
        case .pending: .waitingForGuardian
        case .accepted: .acceptedByGuardian
        case .applied: .applied
        case .failed: .failed
        case .indeterminate: .needsReview
        }
    }
}

public enum ImpactSnapshotCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case unavailable
}

public enum PhoneRestartImpact: Codable, Equatable, Sendable {
    case known(activeTaskCount: Int, uncommittedWorkspaceCount: Int)
    case unknown
}

public struct ImpactSnapshot: Codable, Equatable, Sendable {
    public let targetThreadID: String
    public let serverGeneration: Int64
    public let capturedAt: Date
    public let completeness: ImpactSnapshotCompleteness
    public let impact: PhoneRestartImpact

    public init(
        targetThreadID: String,
        serverGeneration: Int64,
        capturedAt: Date,
        completeness: ImpactSnapshotCompleteness,
        impact: PhoneRestartImpact
    ) {
        self.targetThreadID = targetThreadID
        self.serverGeneration = serverGeneration
        self.capturedAt = capturedAt
        self.completeness = completeness
        self.impact = impact
    }
}

public enum DestructiveActionDenial: Codable, Equatable, Sendable {
    case invalidRequest
    case targetMismatch
    case generationMismatch
    case futureSnapshot
    case staleSnapshot
    case incompleteSnapshot
    case unknownImpact
    case activeTasks(Int)
    case uncommittedWorkspaces(Int)
}

public enum DestructiveActionAuthorization: Codable, Equatable, Sendable {
    case allowed
    case denied(DestructiveActionDenial)
}

public struct DestructiveActionPolicy: Sendable {
    public let maximumSnapshotAge: TimeInterval

    public init(maximumSnapshotAge: TimeInterval) {
        self.maximumSnapshotAge = maximumSnapshotAge
    }

    public func authorization(
        for action: PhoneAction,
        targetThreadID: String,
        expectedGeneration: Int64,
        snapshot: ImpactSnapshot?,
        now: Date
    ) -> DestructiveActionAuthorization {
        guard maximumSnapshotAge > 0,
              maximumSnapshotAge.isFinite,
              !targetThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedGeneration > 0,
              now.timeIntervalSince1970.isFinite else {
            return .denied(.invalidRequest)
        }
        guard action.isDestructive else { return .allowed }
        guard let snapshot,
              snapshot.capturedAt.timeIntervalSince1970.isFinite else {
            return .denied(.unknownImpact)
        }
        guard snapshot.targetThreadID == targetThreadID else {
            return .denied(.targetMismatch)
        }
        guard snapshot.serverGeneration == expectedGeneration else {
            return .denied(.generationMismatch)
        }
        guard snapshot.capturedAt <= now else { return .denied(.futureSnapshot) }
        guard now.timeIntervalSince(snapshot.capturedAt) <= maximumSnapshotAge else {
            return .denied(.staleSnapshot)
        }
        guard snapshot.completeness == .complete else {
            return .denied(.incompleteSnapshot)
        }
        guard case let .known(activeTasks, uncommittedWorkspaces) = snapshot.impact,
              activeTasks >= 0,
              uncommittedWorkspaces >= 0 else {
            return .denied(.unknownImpact)
        }
        guard activeTasks == 0 else { return .denied(.activeTasks(activeTasks)) }
        guard uncommittedWorkspaces == 0 else {
            return .denied(.uncommittedWorkspaces(uncommittedWorkspaces))
        }
        return .allowed
    }
}

public enum OpaqueNotificationError: Error, Equatable, Sendable {
    case invalidPayload
}

public struct OpaqueNotificationPayload: Codable, Equatable, Sendable {
    public let operationID: OperationID
    public let userInfo: [String: String]

    public init(userInfo: [String: String]) throws {
        guard userInfo.count == 1,
              let value = userInfo["operation_id"] else {
            throw OpaqueNotificationError.invalidPayload
        }
        let operationID = OperationID(value)
        guard operationID.isValid else {
            throw OpaqueNotificationError.invalidPayload
        }
        self.operationID = operationID
        self.userInfo = ["operation_id": value]
    }
}

public struct ProjectionCursor: Codable, Equatable, Sendable {
    public let generation: Int64
    public let sequence: UInt64

    public init(generation: Int64, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }

    public func recovery(for envelope: ProjectionEnvelope) -> ProjectionRecovery {
        guard generation > 0,
              envelope.generation == generation,
              sequence < UInt64.max,
              envelope.sequence == sequence + 1 else {
            return .requireFullSnapshot
        }
        return .acceptIncrement
    }
}

public struct ProjectionEnvelope: Codable, Equatable, Sendable {
    public let generation: Int64
    public let sequence: UInt64

    public init(generation: Int64, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }
}

public enum ProjectionRecovery: String, Codable, Equatable, Sendable {
    case acceptIncrement
    case requireFullSnapshot
}

public enum PhoneCapabilityAvailability: String, Codable, Equatable, Sendable {
    case available
    case adapterUnavailable
    case unauthorized
    case temporarilyUnavailable
}

public struct PhoneCapability: Codable, Equatable, Sendable {
    public let action: PhoneAction
    public let availability: PhoneCapabilityAvailability

    public init(action: PhoneAction, availability: PhoneCapabilityAvailability) {
        self.action = action
        self.availability = availability
    }

    public var isActionable: Bool { availability == .available }
}

public enum OfflineCommandEnqueueResult: Equatable, Sendable {
    case inserted
    case duplicateIgnored
    case identifierConflict
}

public struct OfflineCommandQueue: Equatable, Sendable {
    public private(set) var records: [PhoneCommandRecord]

    public init(records: [PhoneCommandRecord] = []) {
        self.records = records
    }

    public mutating func enqueue(
        _ command: PhoneCommandRecord
    ) -> OfflineCommandEnqueueResult {
        guard command.id.isValid else { return .identifierConflict }
        if let existing = records.first(where: { $0.id == command.id }) {
            return existing == command ? .duplicateIgnored : .identifierConflict
        }
        records.append(command)
        return .inserted
    }
}
