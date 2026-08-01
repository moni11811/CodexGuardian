import Foundation

public struct GuardianRemoteEffectAuthorization: Equatable, Sendable {
    public let fences: GuardianRemoteEffectFences
    public let evidenceID: String

    public init(fences: GuardianRemoteEffectFences, evidenceID: String) {
        self.fences = fences
        self.evidenceID = evidenceID
    }

    public var isValid: Bool {
        fences.isValid
            && !evidenceID.isEmpty
            && evidenceID.utf8.count <= 512
    }
}

public struct GuardianRemoteEffectContext: Equatable, Sendable {
    public let binding: GuardianRemotePayloadBinding
    public let adapter: GuardianAdapterIdentity
    public let fences: GuardianRemoteEffectFences
    public let idempotencyKey: UUID
    public let authorizationEvidenceID: String
    public let attemptCount: Int64

    public init(preparation: GuardianRemoteEffectPreparation) {
        binding = preparation.lease.binding
        adapter = preparation.adapter
        fences = preparation.fences
        idempotencyKey = preparation.idempotencyKey
        authorizationEvidenceID = preparation.evidenceID
        attemptCount = preparation.lease.attemptCount
    }

    public var isValid: Bool {
        binding.isValid
            && adapter.isValid
            && fences.isValid
            && idempotencyKey == binding.commandID
            && !authorizationEvidenceID.isEmpty
            && attemptCount > 0
    }
}

public enum GuardianRemoteReconciliationProof: Equatable, Sendable {
    case applied(evidenceID: String)
    case notApplied(evidenceID: String)
    case failed(code: GuardianRemoteCommandFailureCode, evidenceID: String)
    case indeterminate(code: GuardianRemoteCommandFailureCode, evidenceID: String)

    public var hasValidEvidence: Bool {
        let evidenceID: String
        switch self {
        case let .applied(value), let .notApplied(value):
            evidenceID = value
        case let .failed(_, value), let .indeterminate(_, value):
            evidenceID = value
        }
        return !evidenceID.isEmpty && evidenceID.utf8.count <= 512
    }
}

public enum GuardianRemoteApplyResult: Equatable, Sendable {
    case applied(evidenceID: String)
    case failed(code: GuardianRemoteCommandFailureCode, evidenceID: String)
    case indeterminate(code: GuardianRemoteCommandFailureCode, evidenceID: String)

    public var hasValidEvidence: Bool {
        let evidenceID: String
        switch self {
        case let .applied(value):
            evidenceID = value
        case let .failed(_, value), let .indeterminate(_, value):
            evidenceID = value
        }
        return !evidenceID.isEmpty && evidenceID.utf8.count <= 512
    }
}

public protocol GuardianRemoteExecutionAdapter: Sendable {
    var identity: GuardianAdapterIdentity { get }
    func supports(_ action: GuardianRemoteAction) -> Bool
    func reconcile(
        _ context: GuardianRemoteEffectContext
    ) async throws -> GuardianRemoteReconciliationProof
    func apply(
        _ payload: Data,
        context: GuardianRemoteEffectContext
    ) async throws -> GuardianRemoteApplyResult
}

public actor GuardianRemoteCommandExecutor {
    public typealias PayloadOpener = @Sendable (
        GuardianRemoteSealedPayload,
        GuardianRemotePayloadBinding
    ) async throws -> Data
    public typealias AuthorizationProvider = @Sendable (
        GuardianRemotePayloadBinding
    ) async throws -> GuardianRemoteEffectAuthorization

    private let journal: GuardianJournal
    private let ownerID: UUID
    private let currentDaemonGeneration: Int64
    private let leaseDuration: TimeInterval
    private let payloadOpener: PayloadOpener
    private let authorizationProvider: AuthorizationProvider
    private let adapters: [any GuardianRemoteExecutionAdapter]

    public init(
        journal: GuardianJournal,
        ownerID: UUID,
        currentDaemonGeneration: Int64,
        leaseDuration: TimeInterval = 10,
        payloadOpener: @escaping PayloadOpener,
        authorizationProvider: @escaping AuthorizationProvider,
        adapters: [any GuardianRemoteExecutionAdapter]
    ) {
        self.journal = journal
        self.ownerID = ownerID
        self.currentDaemonGeneration = currentDaemonGeneration
        self.leaseDuration = leaseDuration
        self.payloadOpener = payloadOpener
        self.authorizationProvider = authorizationProvider
        self.adapters = adapters
    }

    public func runNext(
        now: Date = Date()
    ) async throws -> GuardianRemoteCommandOutcome? {
        if let reconciliation = try journal.claimRemoteCommandForReconciliation(
            ownerID: ownerID,
            currentDaemonGeneration: currentDaemonGeneration,
            now: now,
            leaseDuration: leaseDuration
        ) {
            return try await reconcileOnly(reconciliation, now: now)
        }
        guard let lease = try journal.claimNextRemoteCommand(
            ownerID: ownerID,
            currentDaemonGeneration: currentDaemonGeneration,
            now: now,
            leaseDuration: leaseDuration
        ) else { return nil }
        guard let adapter = adapters.first(where: {
            $0.supports(lease.binding.action)
        }) else {
            return try journal.completeRemoteCommand(
                lease,
                completion: .failed(.adapterUnavailable),
                at: now
            )
        }
        let payload: Data
        do {
            payload = try await payloadOpener(
                lease.sealedPayload,
                lease.binding
            )
        } catch {
            return try journal.completeRemoteCommand(
                lease,
                completion: .failed(.executionFailed),
                at: now
            )
        }
        let authorization: GuardianRemoteEffectAuthorization
        do {
            authorization = try await authorizationProvider(lease.binding)
        } catch {
            return try journal.completeRemoteCommand(
                lease,
                completion: .failed(.policyDenied),
                at: now
            )
        }
        guard authorization.isValid else {
            return try journal.completeRemoteCommand(
                lease,
                completion: .failed(.policyDenied),
                at: now
            )
        }
        let preparation = try journal.prepareRemoteCommandEffect(
            lease,
            adapter: adapter.identity,
            fences: authorization.fences,
            evidenceID: authorization.evidenceID,
            at: now
        )
        let context = GuardianRemoteEffectContext(preparation: preparation)
        guard context.isValid else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        let proof: GuardianRemoteReconciliationProof
        do {
            proof = try await adapter.reconcile(context)
        } catch {
            return try journal.remoteCommandOutcome(
                commandID: lease.binding.commandID
            )
        }
        guard proof.hasValidEvidence else {
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .indeterminate(.ambiguousEffect),
                at: now
            )
        }
        switch proof {
        case .applied:
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .applied,
                at: now
            )
        case let .failed(code, _):
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .failed(code),
                at: now
            )
        case let .indeterminate(code, _):
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .indeterminate(code),
                at: now
            )
        case .notApplied:
            break
        }

        let invoked = try journal.markRemoteCommandInvoked(preparation, at: now)
        let result: GuardianRemoteApplyResult
        do {
            result = try await adapter.apply(payload, context: context)
        } catch {
            return try journal.remoteCommandOutcome(
                commandID: lease.binding.commandID
            )
        }
        guard result.hasValidEvidence else {
            return try journal.completeRemoteCommand(
                invoked.lease,
                completion: .indeterminate(.ambiguousEffect),
                at: now
            )
        }
        switch result {
        case .applied:
            return try journal.completeRemoteCommand(
                invoked.lease,
                completion: .applied,
                at: now
            )
        case let .failed(code, _):
            return try journal.completeRemoteCommand(
                invoked.lease,
                completion: .failed(code),
                at: now
            )
        case let .indeterminate(code, _):
            return try journal.completeRemoteCommand(
                invoked.lease,
                completion: .indeterminate(code),
                at: now
            )
        }
    }

    private func reconcileOnly(
        _ preparation: GuardianRemoteEffectPreparation,
        now: Date
    ) async throws -> GuardianRemoteCommandOutcome {
        guard let adapter = adapters.first(where: {
            $0.identity == preparation.adapter
        }) else {
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .failed(.adapterUnavailable),
                at: now
            )
        }
        let context = GuardianRemoteEffectContext(preparation: preparation)
        let proof: GuardianRemoteReconciliationProof
        do {
            proof = try await adapter.reconcile(context)
        } catch {
            return try journal.remoteCommandOutcome(
                commandID: preparation.idempotencyKey
            ) ?? GuardianRemoteCommandOutcome(
                receipt: try requiredReceipt(commandID: preparation.idempotencyKey),
                state: .pending
            )
        }
        guard proof.hasValidEvidence else {
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .indeterminate(.ambiguousEffect),
                at: now
            )
        }
        switch proof {
        case .applied:
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .applied,
                at: now
            )
        case let .failed(code, _):
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .failed(code),
                at: now
            )
        case let .indeterminate(code, _):
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .indeterminate(code),
                at: now
            )
        case .notApplied:
            return try journal.completeRemoteCommand(
                preparation.lease,
                completion: .indeterminate(.ambiguousEffect),
                at: now
            )
        }
    }

    private func requiredReceipt(commandID: UUID) throws -> GuardianRemoteReceipt {
        guard let receipt = try journal.remoteReceipt(commandID: commandID) else {
            throw GuardianJournalError.remoteCommandNotFound(commandID)
        }
        return receipt
    }
}
