import Foundation

public enum GuardianOperatorSection: String, Codable, Equatable, Sendable {
    case attention
    case active
    case recent
}

public enum GuardianOperatorActionDenial: Equatable, Sendable {
    case staleSnapshot
    case incompleteInventory
    case blockingTasks([String])
    case unsupportedControlPath
    case macLocalOnly
    case confirmationRequired
}

public enum GuardianOperatorActionAvailability: Equatable, Sendable {
    case enabled
    case disabled(GuardianOperatorActionDenial)
}

public enum GuardianOperatorReadinessNotice: Equatable, Sendable {
    case blocked(operationID: UUID, capabilities: [String])
    case waiting(operationID: UUID, capabilities: [String])
    case degraded(operationID: UUID, capabilities: [String])
}

public struct GuardianOperatorPolicy: Sendable {
    public let maximumSnapshotAge: TimeInterval

    public init(maximumSnapshotAge: TimeInterval) {
        self.maximumSnapshotAge = maximumSnapshotAge
    }

    public func section(for state: AuthoritativeTaskState) -> GuardianOperatorSection {
        switch state {
        case .waitingUser, .stuck, .unknown, .slow:
            .attention
        case .working, .recovering, .running:
            .active
        case .idle, .finished:
            .recent
        }
    }

    public func safeRestartAvailability(
        tasks: [GuardianIPCTaskSnapshot],
        inventoryCompleteness: TaskInventoryCompleteness,
        capturedAt: Date,
        directControlSupported: Bool,
        now: Date = Date()
    ) -> GuardianOperatorActionAvailability {
        guard inventoryCompleteness == .complete else {
            return .disabled(.incompleteInventory)
        }
        let age = now.timeIntervalSince(capturedAt)
        guard age >= 0, age <= maximumSnapshotAge else {
            return .disabled(.staleSnapshot)
        }
        let blocking = tasks.filter {
            $0.state != .idle && $0.state != .finished
        }.map(\.threadID).sorted()
        guard blocking.isEmpty else {
            return .disabled(.blockingTasks(blocking))
        }
        guard directControlSupported else {
            return .disabled(.unsupportedControlPath)
        }
        return .enabled
    }

    public func forceRestartAvailability(
        isMacLocal: Bool,
        isConfirmed: Bool
    ) -> GuardianOperatorActionAvailability {
        guard isMacLocal else { return .disabled(.macLocalOnly) }
        guard isConfirmed else { return .disabled(.confirmationRequired) }
        return .enabled
    }

    public func readinessNotice(
        operations: [GuardianIPCOperationSnapshot]
    ) -> GuardianOperatorReadinessNotice? {
        let ordered = operations.sorted {
            $0.operationID.uuidString < $1.operationID.uuidString
        }
        for operation in ordered {
            if case let .blocked(required)? = operation.readiness {
                return .blocked(
                    operationID: operation.operationID,
                    capabilities: required.sorted()
                )
            }
        }
        for operation in ordered {
            if case let .waiting(required)? = operation.readiness {
                return .waiting(
                    operationID: operation.operationID,
                    capabilities: required.sorted()
                )
            }
        }
        for operation in ordered {
            if case let .ready(degraded)? = operation.readiness, !degraded.isEmpty {
                return .degraded(
                    operationID: operation.operationID,
                    capabilities: degraded.sorted()
                )
            }
        }
        return nil
    }
}
