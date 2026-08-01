import Foundation

public enum GuardianCapabilityRequirement: String, Codable, Equatable, Sendable {
    case required
    case optional
}

public enum GuardianCapabilityState: String, Codable, Equatable, Sendable {
    case pending
    case ready
    case failed
    case degraded
}

public struct GuardianCapabilityRecord: Codable, Equatable, Sendable {
    public let capability: String
    public let requirement: GuardianCapabilityRequirement
    public let state: GuardianCapabilityState
    public let evidenceID: String
    public let observedAt: Date
    public let deadline: Date

    public init(
        capability: String,
        requirement: GuardianCapabilityRequirement,
        state: GuardianCapabilityState,
        evidenceID: String,
        observedAt: Date,
        deadline: Date
    ) {
        self.capability = capability
        self.requirement = requirement
        self.state = state
        self.evidenceID = evidenceID
        self.observedAt = observedAt
        self.deadline = deadline
    }

    public var isValid: Bool {
        !capability.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !evidenceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && observedAt.timeIntervalSince1970.isFinite
            && deadline.timeIntervalSince1970.isFinite
            && observedAt <= deadline
            && !(requirement == .required && state == .degraded)
    }
}

public enum GuardianReadinessDecision: Codable, Equatable, Sendable {
    case ready(degraded: [String])
    case waiting(required: [String])
    case blocked(required: [String])
}

public struct GuardianReadinessPolicy: Sendable {
    public init() {}

    public func decision(
        records: [GuardianCapabilityRecord],
        now: Date = Date()
    ) -> GuardianReadinessDecision {
        guard now.timeIntervalSince1970.isFinite else {
            return .blocked(required: ["readiness.manifest"])
        }
        guard !records.isEmpty else {
            return .blocked(required: ["readiness.manifest"])
        }
        var unique: [String: GuardianCapabilityRecord] = [:]
        for record in records {
            guard record.isValid else {
                return .blocked(required: ["readiness.manifest"])
            }
            if let existing = unique[record.capability], existing != record {
                return .blocked(required: ["readiness.manifest"])
            }
            unique[record.capability] = record
        }

        var blocked: [String] = []
        var waiting: [String] = []
        var degraded: [String] = []
        for record in unique.values {
            switch (record.requirement, record.state) {
            case (.required, .ready):
                break
            case (.required, .pending):
                if record.deadline > now {
                    waiting.append(record.capability)
                } else {
                    blocked.append(record.capability)
                }
            case (.required, .failed), (.required, .degraded):
                blocked.append(record.capability)
            case (.optional, .ready):
                break
            case (.optional, .pending):
                if record.deadline <= now {
                    degraded.append(record.capability)
                }
            case (.optional, .failed), (.optional, .degraded):
                degraded.append(record.capability)
            }
        }

        if !blocked.isEmpty {
            return .blocked(required: blocked.sorted())
        }
        if !waiting.isEmpty {
            return .waiting(required: waiting.sorted())
        }
        return .ready(degraded: degraded.sorted())
    }
}
