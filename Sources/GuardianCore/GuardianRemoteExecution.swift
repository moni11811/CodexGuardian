import Foundation

public enum GuardianRemoteLeasePurpose: String, Equatable, Sendable {
    case execution
    case reconciliation
}

public struct GuardianAdapterIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }

    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128
            && !version.isEmpty && version.utf8.count <= 128
    }
}

public struct GuardianRemoteEffectFences: Codable, Equatable, Sendable {
    public let authorityEpoch: Int64
    public let policyEpoch: Int64
    public let targetRevision: String

    public init(
        authorityEpoch: Int64,
        policyEpoch: Int64,
        targetRevision: String
    ) {
        self.authorityEpoch = authorityEpoch
        self.policyEpoch = policyEpoch
        self.targetRevision = targetRevision
    }

    public var isValid: Bool {
        authorityEpoch >= 0
            && policyEpoch >= 0
            && !targetRevision.isEmpty
            && targetRevision.utf8.count <= 512
    }
}

public struct GuardianRemoteCommandLease: Equatable, Sendable {
    public let binding: GuardianRemotePayloadBinding
    public let sealedPayload: GuardianRemoteSealedPayload
    public let ownerID: UUID
    public let leaseGeneration: Int64
    public let leaseExpiresAt: Date
    public let attemptCount: Int64
    public let daemonGeneration: Int64
    public let version: Int64
    public let purpose: GuardianRemoteLeasePurpose

    public init(
        binding: GuardianRemotePayloadBinding,
        sealedPayload: GuardianRemoteSealedPayload,
        ownerID: UUID,
        leaseGeneration: Int64,
        leaseExpiresAt: Date,
        attemptCount: Int64,
        daemonGeneration: Int64,
        version: Int64,
        purpose: GuardianRemoteLeasePurpose
    ) {
        self.binding = binding
        self.sealedPayload = sealedPayload
        self.ownerID = ownerID
        self.leaseGeneration = leaseGeneration
        self.leaseExpiresAt = leaseExpiresAt
        self.attemptCount = attemptCount
        self.daemonGeneration = daemonGeneration
        self.version = version
        self.purpose = purpose
    }

    public var resource: String {
        "remote-command:\(binding.commandID.uuidString)"
    }

    public var isValid: Bool {
        binding.isValid
            && sealedPayload.isValid
            && leaseGeneration > 0
            && leaseExpiresAt.timeIntervalSince1970.isFinite
            && (purpose == .reconciliation || leaseExpiresAt <= binding.deadline)
            && attemptCount > 0
            && daemonGeneration > 0
            && version > 1
    }
}

public struct GuardianRemoteEffectPreparation: Equatable, Sendable {
    public let lease: GuardianRemoteCommandLease
    public let adapter: GuardianAdapterIdentity
    public let fences: GuardianRemoteEffectFences
    public let idempotencyKey: UUID
    public let evidenceID: String
    public let preparedAt: Date

    public init(
        lease: GuardianRemoteCommandLease,
        adapter: GuardianAdapterIdentity,
        fences: GuardianRemoteEffectFences,
        idempotencyKey: UUID,
        evidenceID: String,
        preparedAt: Date
    ) {
        self.lease = lease
        self.adapter = adapter
        self.fences = fences
        self.idempotencyKey = idempotencyKey
        self.evidenceID = evidenceID
        self.preparedAt = preparedAt
    }

    public var isValid: Bool {
        lease.isValid
            && adapter.isValid
            && fences.isValid
            && idempotencyKey == lease.binding.commandID
            && !evidenceID.isEmpty
            && evidenceID.utf8.count <= 512
            && preparedAt.timeIntervalSince1970.isFinite
    }
}
