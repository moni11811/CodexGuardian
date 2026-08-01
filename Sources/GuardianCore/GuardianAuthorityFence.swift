import Foundation

public enum GuardianAuthorityOwner: String, Codable, Equatable, Sendable {
    case legacy
    case daemon
}

public enum GuardianAuthorityPhase: String, Codable, Equatable, Sendable {
    case legacyAuthoritative = "legacy_authoritative"
    case prepared
    case daemonAuthoritative = "daemon_authoritative"
}

public struct GuardianAuthorityCutoverProof: Codable, Equatable, Sendable {
    public let desktopControlEvidenceID: String
    public let observerComparisonEvidenceID: String
    public let deploymentID: String
    public let daemonGeneration: Int64

    public init(
        desktopControlEvidenceID: String,
        observerComparisonEvidenceID: String,
        deploymentID: String,
        daemonGeneration: Int64
    ) {
        self.desktopControlEvidenceID = desktopControlEvidenceID
        self.observerComparisonEvidenceID = observerComparisonEvidenceID
        self.deploymentID = deploymentID
        self.daemonGeneration = daemonGeneration
    }

    public var isComplete: Bool {
        !desktopControlEvidenceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !observerComparisonEvidenceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !deploymentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && daemonGeneration > 0
    }
}

public struct GuardianAuthorityFence: Codable, Equatable, Sendable {
    public static let cutoverLeaseResource = "guardian-authority-cutover"
    public static let schemaVersion = 1

    public let phase: GuardianAuthorityPhase
    public let epoch: Int64
    public let proof: GuardianAuthorityCutoverProof?
    public let updatedAt: Date

    public init(
        phase: GuardianAuthorityPhase,
        epoch: Int64,
        proof: GuardianAuthorityCutoverProof?,
        updatedAt: Date
    ) {
        self.phase = phase
        self.epoch = epoch
        self.proof = proof
        self.updatedAt = updatedAt
    }

    public var owner: GuardianAuthorityOwner {
        switch phase {
        case .legacyAuthoritative, .prepared:
            return .legacy
        case .daemonAuthoritative:
            return .daemon
        }
    }

    public var isValid: Bool {
        guard epoch >= 0, updatedAt.timeIntervalSince1970.isFinite else { return false }
        switch phase {
        case .legacyAuthoritative:
            return proof == nil && epoch == 0
        case .prepared:
            return proof?.isComplete == true
        case .daemonAuthoritative:
            return proof?.isComplete == true && epoch > 0
        }
    }
}

public struct GuardianAuthorityPermit: Codable, Equatable, Sendable {
    public let owner: GuardianAuthorityOwner
    public let epoch: Int64
    public let issuedAt: Date

    public init(owner: GuardianAuthorityOwner, epoch: Int64, issuedAt: Date) {
        self.owner = owner
        self.epoch = epoch
        self.issuedAt = issuedAt
    }
}

public struct GuardianAuthorityEvent: Codable, Equatable, Sendable {
    public let index: Int64
    public let from: GuardianAuthorityPhase
    public let to: GuardianAuthorityPhase
    public let epoch: Int64
    public let proof: GuardianAuthorityCutoverProof
    public let occurredAt: Date

    public init(
        index: Int64,
        from: GuardianAuthorityPhase,
        to: GuardianAuthorityPhase,
        epoch: Int64,
        proof: GuardianAuthorityCutoverProof,
        occurredAt: Date
    ) {
        self.index = index
        self.from = from
        self.to = to
        self.epoch = epoch
        self.proof = proof
        self.occurredAt = occurredAt
    }
}

public enum GuardianAuthorityFenceError: Error, Equatable, Sendable {
    case authorityDenied(GuardianAuthorityOwner)
    case stalePermit
    case invalidCutoverProof
    case inventoryNotAuthoritative
    case legacyOperationInFlight(UUID)
    case daemonGenerationMismatch(expected: Int64, actual: Int64)
    case invalidLeaseResource
    case invalidTransition(from: GuardianAuthorityPhase, to: GuardianAuthorityPhase)
    case staleEpoch(expected: Int64, actual: Int64)
    case unprovable
}
