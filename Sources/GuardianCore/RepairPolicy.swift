import Foundation

public enum RepairFailureFamily: String, Codable, Equatable, Sendable {
    case tool
    case mcpHost
    case controlPlane
    case thread
    case desktop
    case permission
    case disk
    case network
    case externalDependency
}

public enum RepairFailureNature: String, Codable, Equatable, Sendable {
    case transient
    case deterministic
    case environment
    case permission
    case externalDependency
}

public enum RepairCapabilityCriticality: Codable, Equatable, Sendable {
    case required
    case optional(capability: String)
}

public struct RepairIncident: Codable, Equatable, Sendable {
    public let family: RepairFailureFamily
    public let nature: RepairFailureNature
    public let criticality: RepairCapabilityCriticality
    public let symptom: String
    public let missingProof: String
    public let startedAt: Date
    public let deadline: Date

    public init(
        family: RepairFailureFamily,
        nature: RepairFailureNature,
        criticality: RepairCapabilityCriticality,
        symptom: String,
        missingProof: String,
        startedAt: Date,
        deadline: Date
    ) {
        self.family = family
        self.nature = nature
        self.criticality = criticality
        self.symptom = symptom
        self.missingProof = missingProof
        self.startedAt = startedAt
        self.deadline = deadline
    }
}

public enum RepairAction: String, Codable, Equatable, Sendable {
    case retryOnce
    case reloadToolHost
    case reloadMCPHost
    case steerAffectedTurn
    case reconnectControlPlane
    case restartDesktop
    case notifyUser
}

public enum RepairAttemptResult: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case timedOut
}

public struct RepairAttempt: Codable, Equatable, Sendable {
    public let action: RepairAction
    public let changedVariable: String?
    public let result: RepairAttemptResult
    public let occurredAt: Date

    public init(
        action: RepairAction,
        changedVariable: String?,
        result: RepairAttemptResult,
        occurredAt: Date
    ) {
        self.action = action
        self.changedVariable = changedVariable
        self.result = result
        self.occurredAt = occurredAt
    }
}

public struct RepairProposal: Equatable, Sendable {
    public let action: RepairAction
    public let changedVariable: String?

    public init(action: RepairAction, changedVariable: String?) {
        self.action = action
        self.changedVariable = changedVariable
    }
}

public enum RepairDenial: Equatable, Sendable {
    case unchangedDeterministicRetry
    case changedVariableRequired
    case circuitOpen
    case restartBudgetExhausted
    case cooldown(until: Date)
    case deadlineExceeded
}

public enum RepairAuthorization: Equatable, Sendable {
    case allowed(attemptDeadline: Date)
    case denied(RepairDenial)
}

public enum RepairDecision: Equatable, Sendable {
    case perform(RepairAction, attemptDeadline: Date)
    case resolved(by: RepairAction)
    case degraded(capability: String, failure: RepairFailureFamily, recordedAt: Date)
    case blocked(RepairDenial)
}

public struct RepairPolicyConfiguration: Codable, Equatable, Sendable {
    public let attemptTimeout: TimeInterval
    public let restartWindow: TimeInterval
    public let maximumRestartsPerWindow: Int
    public let restartCooldown: TimeInterval
    public let circuitFailureThreshold: Int

    public init(
        attemptTimeout: TimeInterval,
        restartWindow: TimeInterval,
        maximumRestartsPerWindow: Int,
        restartCooldown: TimeInterval,
        circuitFailureThreshold: Int
    ) {
        self.attemptTimeout = attemptTimeout
        self.restartWindow = restartWindow
        self.maximumRestartsPerWindow = maximumRestartsPerWindow
        self.restartCooldown = restartCooldown
        self.circuitFailureThreshold = circuitFailureThreshold
    }

    public static let test = RepairPolicyConfiguration(
        attemptTimeout: 5,
        restartWindow: 3_600,
        maximumRestartsPerWindow: 2,
        restartCooldown: 10,
        circuitFailureThreshold: 2
    )

    public static let production = RepairPolicyConfiguration(
        attemptTimeout: 30,
        restartWindow: 3_600,
        maximumRestartsPerWindow: 2,
        restartCooldown: 60,
        circuitFailureThreshold: 2
    )
}

public struct DesktopRestartRecord: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let result: RepairAttemptResult

    public init(occurredAt: Date, result: RepairAttemptResult) {
        self.occurredAt = occurredAt
        self.result = result
    }
}

public struct RestartCircuitState: Codable, Equatable, Sendable {
    public let records: [DesktopRestartRecord]
    public let isOpen: Bool
    public let openedAt: Date?
    public let lastManualResetAt: Date?

    public init(
        records: [DesktopRestartRecord],
        isOpen: Bool,
        openedAt: Date?,
        lastManualResetAt: Date?
    ) {
        self.records = records
        self.isOpen = isOpen
        self.openedAt = openedAt
        self.lastManualResetAt = lastManualResetAt
    }

    public static let empty = RestartCircuitState(
        records: [],
        isOpen: false,
        openedAt: nil,
        lastManualResetAt: nil
    )

    public func recordingDesktopRestart(
        at date: Date,
        result: RepairAttemptResult,
        configuration: RepairPolicyConfiguration
    ) -> RestartCircuitState {
        let updatedRecords = records + [DesktopRestartRecord(occurredAt: date, result: result)]
        let consecutiveFailures = updatedRecords.reversed().prefix {
            $0.result != .succeeded
        }.count
        let shouldOpen = isOpen || consecutiveFailures >= configuration.circuitFailureThreshold
        return RestartCircuitState(
            records: updatedRecords,
            isOpen: shouldOpen,
            openedAt: shouldOpen ? (openedAt ?? date) : nil,
            lastManualResetAt: lastManualResetAt
        )
    }

    public func manuallyReset(at date: Date) -> RestartCircuitState {
        RestartCircuitState(
            records: records,
            isOpen: false,
            openedAt: nil,
            lastManualResetAt: date
        )
    }
}

public struct GuardianStoredRestartCircuit: Codable, Equatable, Sendable {
    public let scope: String
    public let state: RestartCircuitState
    public let version: Int64
    public let updatedAt: Date

    public init(
        scope: String,
        state: RestartCircuitState,
        version: Int64,
        updatedAt: Date
    ) {
        self.scope = scope
        self.state = state
        self.version = version
        self.updatedAt = updatedAt
    }
}

public struct RepairPolicy: Sendable {
    public let configuration: RepairPolicyConfiguration

    public init(configuration: RepairPolicyConfiguration) {
        self.configuration = configuration
    }

    public func authorize(
        proposal: RepairProposal,
        incident: RepairIncident,
        previousAttempts: [RepairAttempt],
        now: Date
    ) -> RepairAuthorization {
        guard now < incident.deadline else {
            return .denied(.deadlineExceeded)
        }
        let changed = proposal.changedVariable?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if proposal.action == .retryOnce,
           incident.nature == .deterministic,
           changed?.isEmpty != false {
            return .denied(.unchangedDeterministicRetry)
        }
        if previousAttempts.contains(where: { $0.action == proposal.action }),
           changed?.isEmpty != false {
            return .denied(.changedVariableRequired)
        }
        return .allowed(attemptDeadline: min(
            now.addingTimeInterval(configuration.attemptTimeout),
            incident.deadline
        ))
    }

    public func nextDecision(
        for incident: RepairIncident,
        attempts: [RepairAttempt],
        restartState: RestartCircuitState,
        now: Date
    ) -> RepairDecision {
        if case let .optional(capability) = incident.criticality {
            return .degraded(
                capability: capability,
                failure: incident.family,
                recordedAt: now
            )
        }
        if let successful = attempts.last(where: { $0.result == .succeeded }) {
            return .resolved(by: successful.action)
        }
        guard now < incident.deadline else {
            return .blocked(.deadlineExceeded)
        }

        if incident.nature == .transient,
           !attempts.contains(where: { $0.action == .retryOnce }) {
            return .perform(
                .retryOnce,
                attemptDeadline: boundedAttemptDeadline(now: now, operationDeadline: incident.deadline)
            )
        }

        let attemptedActions = Set(attempts.map(\.action))
        let ladder = repairLadder(for: incident.family)
        guard let next = ladder.first(where: { !attemptedActions.contains($0) }) else {
            return .blocked(.circuitOpen)
        }
        if next == .restartDesktop {
            switch desktopRestartAuthorization(
                state: restartState,
                now: now,
                operationDeadline: incident.deadline
            ) {
            case let .allowed(attemptDeadline):
                return .perform(.restartDesktop, attemptDeadline: attemptDeadline)
            case let .denied(reason):
                return .blocked(reason)
            }
        }
        return .perform(
            next,
            attemptDeadline: boundedAttemptDeadline(now: now, operationDeadline: incident.deadline)
        )
    }

    public func desktopRestartAuthorization(
        state: RestartCircuitState,
        now: Date,
        operationDeadline: Date
    ) -> RepairAuthorization {
        guard now < operationDeadline else {
            return .denied(.deadlineExceeded)
        }
        guard !state.isOpen else {
            return .denied(.circuitOpen)
        }
        let cutoff = now.addingTimeInterval(-configuration.restartWindow)
        let recent = state.records.filter { $0.occurredAt >= cutoff && $0.occurredAt <= now }
        guard recent.count < configuration.maximumRestartsPerWindow else {
            return .denied(.restartBudgetExhausted)
        }
        if let latest = recent.map(\.occurredAt).max() {
            let cooldownEnd = latest.addingTimeInterval(configuration.restartCooldown)
            guard now >= cooldownEnd else {
                return .denied(.cooldown(until: cooldownEnd))
            }
        }
        return .allowed(attemptDeadline: boundedAttemptDeadline(
            now: now,
            operationDeadline: operationDeadline
        ))
    }

    private func boundedAttemptDeadline(now: Date, operationDeadline: Date) -> Date {
        min(now.addingTimeInterval(configuration.attemptTimeout), operationDeadline)
    }

    private func repairLadder(for family: RepairFailureFamily) -> [RepairAction] {
        switch family {
        case .tool:
            return [.reloadToolHost, .steerAffectedTurn, .reconnectControlPlane, .restartDesktop]
        case .mcpHost:
            return [.reloadMCPHost, .reconnectControlPlane, .restartDesktop]
        case .controlPlane:
            return [.reconnectControlPlane, .restartDesktop]
        case .thread:
            return [.steerAffectedTurn, .reconnectControlPlane, .restartDesktop]
        case .desktop:
            return [.restartDesktop]
        case .permission, .disk, .network, .externalDependency:
            return [.notifyUser]
        }
    }
}
