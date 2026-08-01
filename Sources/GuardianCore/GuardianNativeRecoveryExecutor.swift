import Foundation

public enum GuardianNativeRecoveryExecutionResult: Equatable, Sendable {
    case delivered(
        registration: GuardianNativeRecoveryRegistration,
        delivery: CodexAppServerRecoveryDelivery,
        alreadySubmitted: Bool
    )
    case terminalFailure(
        operationID: UUID,
        threadID: String,
        turnID: String,
        outcome: CodexAppServerRecoveryCompletion
    )
}

public struct GuardianNativeRecoveryExecutor: Sendable {
    private let journal: GuardianJournal
    private let outbox: GuardianProtectedOutbox
    private let store: RestartRequestStore
    private let registrar: GuardianNativeRecoveryRegistrar

    public init(
        journal: GuardianJournal,
        outbox: GuardianProtectedOutbox,
        store: RestartRequestStore
    ) {
        self.journal = journal
        self.outbox = outbox
        self.store = store
        self.registrar = GuardianNativeRecoveryRegistrar(
            journal: journal,
            outbox: outbox
        )
    }

    public func execute(
        request: RestartRequest,
        transport: any CodexAppServerRecoveryTransport,
        deadline: Date,
        livenessPolicy: CodexAppServerRecoveryLivenessPolicy = .production
    ) async throws -> GuardianNativeRecoveryExecutionResult {
        guard request.requestMode == .nativeFirst,
              let tokenText = request.originToken,
              let originToken = UUID(uuidString: tokenText),
              deadline > Date() else {
            throw GuardianNativeRecoveryRegistrationError.invalidInput
        }

        let registration = try await registrar.register(
            originToken: originToken,
            threadID: request.threadID,
            recoveryPrompt: request.recoveryPrompt
        )
        try store.markClaimNativeExecuting(
            id: request.id,
            operationID: registration.operationID,
            generation: registration.generation
        )

        let storedEntries = try journal.outboxEntries(
            operationID: registration.operationID
        )
        guard storedEntries.count == 1, let storedEntry = storedEntries.first else {
            throw GuardianJournalError.outboxNotFound(registration.operationID)
        }
        let envelope = try JSONDecoder().decode(
            GuardianNativeRecoveryEnvelope.self,
            from: try await outbox.open(storedEntry)
        )
        guard envelope.originToken == originToken,
              envelope.generation == registration.generation,
              storedEntry.targetThreadID == request.threadID else {
            throw GuardianJournalError.outboxConflict(registration.operationID)
        }

        if storedEntry.state == .accepted,
           let receipt = storedEntry.receipt {
            try store.markNativeAwaitingAcknowledgement(id: request.id)
            return .delivered(
                registration: registration,
                delivery: CodexAppServerRecoveryDelivery(
                    threadID: receipt.targetThreadID,
                    turnID: receipt.turnID,
                    clientMessageID: CodexAppServerRecoveryProtocol.clientMessageID(
                        originToken: originToken,
                        generation: registration.generation
                    ),
                    userMessageItemID: receipt.messageItemID
                ),
                alreadySubmitted: true
            )
        }

        switch storedEntry.state {
        case .pending:
            _ = try journal.beginOutboxDeliveryAttempt(
                messageID: storedEntry.messageID
            )
        case .awaitingReconciliation:
            break
        case .accepted, .acknowledged, .deadLetter:
            throw GuardianNativeRecoveryRegistrationError.operationClosed
        }

        let recoveryOutcome = try CodexAppServerRecoveryCoordinator().recover(
            threadID: request.threadID,
            prompt: continuationPrompt(
                envelope: envelope,
                operationID: registration.operationID
            ),
            originToken: originToken,
            generation: registration.generation,
            transport: transport,
            deadline: deadline,
            livenessPolicy: livenessPolicy
        )
        switch recoveryOutcome {
        case .alreadySubmitted(let delivery):
            try record(
                delivery: delivery,
                registration: registration,
                request: request
            )
            return .delivered(
                registration: registration,
                delivery: delivery,
                alreadySubmitted: true
            )
        case .completed(let delivery):
            try record(
                delivery: delivery,
                registration: registration,
                request: request
            )
            return .delivered(
                registration: registration,
                delivery: delivery,
                alreadySubmitted: false
            )
        case .interrupted(let threadID, let turnID):
            return try terminalFailure(
                registration: registration,
                request: request,
                threadID: threadID,
                turnID: turnID,
                outcome: .interrupted
            )
        case .failed(let threadID, let turnID):
            return try terminalFailure(
                registration: registration,
                request: request,
                threadID: threadID,
                turnID: turnID,
                outcome: .failed
            )
        }
    }

    private func record(
        delivery: CodexAppServerRecoveryDelivery,
        registration: GuardianNativeRecoveryRegistration,
        request: RestartRequest
    ) throws {
        guard delivery.threadID == request.threadID else {
            throw GuardianJournalError.deliveryReceiptMismatch(registration.operationID)
        }
        try journal.recordDeliveryReceipt(GuardianDeliveryReceipt(
            operationID: registration.operationID,
            messageID: registration.operationID,
            targetThreadID: delivery.threadID,
            messageItemID: delivery.userMessageItemID,
            turnID: delivery.turnID,
            acceptedAt: Date()
        ))
        try store.markNativeAwaitingAcknowledgement(id: request.id)
    }

    private func terminalFailure(
        registration: GuardianNativeRecoveryRegistration,
        request: RestartRequest,
        threadID: String,
        turnID: String,
        outcome: CodexAppServerRecoveryCompletion
    ) throws -> GuardianNativeRecoveryExecutionResult {
        try journal.transition(
            operationID: registration.operationID,
            to: .failed,
            context: GuardianTransitionContext(
                actor: .codex,
                reason: "native-recovery.\(outcome.rawValue)"
            )
        )
        try store.markNativeFailed(id: request.id)
        return .terminalFailure(
            operationID: registration.operationID,
            threadID: threadID,
            turnID: turnID,
            outcome: outcome
        )
    }

    private func continuationPrompt(
        envelope: GuardianNativeRecoveryEnvelope,
        operationID: UUID
    ) -> String {
        """
        \(envelope.recoveryPrompt)

        Codex Guardian recovery operation \(operationID.uuidString). After meaningful progress, call the Codex Guardian ack_recovery tool with origin_token \(envelope.originToken.uuidString). Do not acknowledge before meaningful progress.
        """
    }
}
