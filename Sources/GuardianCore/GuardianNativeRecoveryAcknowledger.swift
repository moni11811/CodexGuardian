import Foundation

public enum GuardianNativeRecoveryAcknowledgementError: Error, Equatable, Sendable {
    case invalidOriginToken
    case requestNotFound
    case requestNotAwaitingAcknowledgement
    case recoveryIdentityMismatch
    case deliveryReceiptMissing
}

extension GuardianNativeRecoveryAcknowledgementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidOriginToken:
            return "The recovery origin token is invalid."
        case .requestNotFound:
            return "The native recovery operation was not found."
        case .requestNotAwaitingAcknowledgement:
            return "The native recovery is not awaiting acknowledgement."
        case .recoveryIdentityMismatch:
            return "The recovery operation does not match the exact originating task."
        case .deliveryReceiptMissing:
            return "The exact recovery delivery receipt is missing."
        }
    }
}

public struct GuardianNativeRecoveryAcknowledgement: Equatable, Sendable {
    public let operationID: UUID
    public let threadID: String
    public let turnID: String
    public let messageItemID: String
    public let alreadyAcknowledged: Bool

    public init(
        operationID: UUID,
        threadID: String,
        turnID: String,
        messageItemID: String,
        alreadyAcknowledged: Bool
    ) {
        self.operationID = operationID
        self.threadID = threadID
        self.turnID = turnID
        self.messageItemID = messageItemID
        self.alreadyAcknowledged = alreadyAcknowledged
    }
}

public struct GuardianNativeRecoveryAcknowledger: Sendable {
    private let journal: GuardianJournal
    private let store: RestartRequestStore

    public init(journal: GuardianJournal, store: RestartRequestStore) {
        self.journal = journal
        self.store = store
    }

    public func acknowledge(
        originToken tokenText: String
    ) throws -> GuardianNativeRecoveryAcknowledgement {
        guard let originToken = UUID(uuidString: tokenText) else {
            throw GuardianNativeRecoveryAcknowledgementError.invalidOriginToken
        }
        let originHash = GuardianRecoveryOriginIdentity.hash(
            originToken: originToken
        )
        guard let operation = try journal.operation(
            originTokenHash: originHash
        ) else {
            throw GuardianNativeRecoveryAcknowledgementError.requestNotFound
        }
        guard operation.kind == .nativeRecovery else {
            throw GuardianNativeRecoveryAcknowledgementError.recoveryIdentityMismatch
        }
        let entries = try journal.outboxEntries(operationID: operation.id)
        guard entries.count == 1,
              let entry = entries.first,
              let receipt = entry.receipt else {
            throw GuardianNativeRecoveryAcknowledgementError.deliveryReceiptMissing
        }
        guard receipt.operationID == operation.id,
              receipt.messageID == operation.id,
              receipt.targetThreadID == operation.originThreadID else {
            throw GuardianNativeRecoveryAcknowledgementError.recoveryIdentityMismatch
        }

        let request = try store.request(originToken: tokenText)
        if let request {
            guard request.requestMode == .nativeFirst,
                  request.recoveryPhase == .nativeAwaitingAcknowledgement else {
                throw GuardianNativeRecoveryAcknowledgementError
                    .requestNotAwaitingAcknowledgement
            }
            guard request.nativeOperationID == operation.id,
                  request.threadID == operation.originThreadID,
                  request.originToken.flatMap(UUID.init(uuidString:)) == originToken else {
                throw GuardianNativeRecoveryAcknowledgementError
                    .recoveryIdentityMismatch
            }
        } else {
            guard operation.phase == .acknowledged,
                  entry.state == .acknowledged else {
                throw GuardianNativeRecoveryAcknowledgementError.requestNotFound
            }
            return result(
                operation: operation,
                receipt: receipt,
                alreadyAcknowledged: true
            )
        }

        let wasAcknowledged = operation.phase == .acknowledged
        switch (operation.phase, entry.state) {
        case (.deliveryReceipt, .accepted):
            try journal.acknowledgeOperation(
                operationID: operation.id,
                at: max(Date(), receipt.acceptedAt)
            )
        case (.acknowledged, .acknowledged):
            break
        default:
            throw GuardianNativeRecoveryAcknowledgementError
                .requestNotAwaitingAcknowledgement
        }
        guard try store.acknowledgeNativeRecovery(
            originToken: tokenText
        ) != nil else {
            throw GuardianNativeRecoveryAcknowledgementError
                .requestNotAwaitingAcknowledgement
        }
        return result(
            operation: operation,
            receipt: receipt,
            alreadyAcknowledged: wasAcknowledged
        )
    }

    private func result(
        operation: GuardianOperation,
        receipt: GuardianDeliveryReceipt,
        alreadyAcknowledged: Bool
    ) -> GuardianNativeRecoveryAcknowledgement {
        GuardianNativeRecoveryAcknowledgement(
            operationID: operation.id,
            threadID: operation.originThreadID,
            turnID: receipt.turnID,
            messageItemID: receipt.messageItemID,
            alreadyAcknowledged: alreadyAcknowledged
        )
    }
}
