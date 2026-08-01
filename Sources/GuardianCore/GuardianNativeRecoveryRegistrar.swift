import CryptoKit
import Foundation

public enum GuardianNativeRecoveryRegistrationError: Error, Equatable, Sendable {
    case invalidInput
    case operationClosed
}

public struct GuardianNativeRecoveryEnvelope: Codable, Equatable, Sendable {
    public let originToken: UUID
    public let generation: UInt64
    public let recoveryPrompt: String

    public init(originToken: UUID, generation: UInt64, recoveryPrompt: String) {
        self.originToken = originToken
        self.generation = generation
        self.recoveryPrompt = recoveryPrompt
    }
}

public struct GuardianNativeRecoveryRegistration: Equatable, Sendable {
    public let operationID: UUID
    public let threadID: String
    public let generation: UInt64

    public init(operationID: UUID, threadID: String, generation: UInt64) {
        self.operationID = operationID
        self.threadID = threadID
        self.generation = generation
    }
}

public enum GuardianRecoveryOriginIdentity {
    public static func hash(originToken: UUID) -> String {
        SHA256.hash(data: Data(originToken.uuidString.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public actor GuardianNativeRecoveryRegistrar {
    private let journal: GuardianJournal
    private let outbox: GuardianProtectedOutbox

    public init(journal: GuardianJournal, outbox: GuardianProtectedOutbox) {
        self.journal = journal
        self.outbox = outbox
    }

    public func register(
        originToken: UUID,
        threadID: String,
        recoveryPrompt: String,
        at date: Date = Date()
    ) async throws -> GuardianNativeRecoveryRegistration {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = recoveryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty,
              !normalizedPrompt.isEmpty,
              date.timeIntervalSince1970.isFinite else {
            throw GuardianNativeRecoveryRegistrationError.invalidInput
        }

        let generation: UInt64 = 1
        let candidate = GuardianOperation(
            id: UUID(),
            kind: .nativeRecovery,
            originThreadID: normalizedThreadID,
            originTokenHash: GuardianRecoveryOriginIdentity.hash(originToken: originToken),
            phase: .prepared,
            createdAt: date,
            updatedAt: date
        )
        var operation = try journal.createOrGet(candidate)
        if operation.phase == .prepared {
            let transitionDate = max(date, operation.updatedAt)
                .addingTimeInterval(0.000_001)
            try journal.transition(
                operationID: operation.id,
                to: .targetLoaded,
                context: GuardianTransitionContext(
                    actor: .client,
                    reason: "native-recovery.target-bound"
                ),
                at: transitionDate
            )
            operation = try requireOperation(id: operation.id)
        }
        guard [.targetLoaded, .continuationSent, .deliveryReceipt].contains(operation.phase) else {
            throw GuardianNativeRecoveryRegistrationError.operationClosed
        }

        let envelope = GuardianNativeRecoveryEnvelope(
            originToken: originToken,
            generation: generation,
            recoveryPrompt: normalizedPrompt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        _ = try await outbox.enqueue(
            operationID: operation.id,
            targetThreadID: normalizedThreadID,
            plaintext: try encoder.encode(envelope),
            at: max(date, operation.updatedAt)
        )
        return GuardianNativeRecoveryRegistration(
            operationID: operation.id,
            threadID: normalizedThreadID,
            generation: generation
        )
    }

    private func requireOperation(id: UUID) throws -> GuardianOperation {
        guard let operation = try journal.operation(id: id) else {
            throw GuardianJournalError.operationNotFound(id)
        }
        return operation
    }
}
