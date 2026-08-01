import Foundation

public enum GuardianJournalFaultPoint: Equatable, Sendable {
    case operationInsertedBeforeInitialEvent
    case operationPhaseUpdatedBeforeEvent(GuardianOperationPhase)
    case outboxInsertedBeforePhaseTransition
    case receiptStoredBeforePhaseTransition
    case acknowledgementStoredBeforePhaseTransition
    case authorityPreparedBeforeEvent
    case authorityActivatedBeforeEvent
    case remotePairingConsumedBeforeDevice
    case remoteCommandInsertedBeforeReceipt
    case remoteRevocationUpdatedBeforeAudit
    case daemonEventInsertedBeforeSequenceAdvance
    case remoteCommandOutcomeUpdatedBeforeAudit
    case remoteExecutionQueuedBeforeDeviceAdvance
    case remoteExecutionClaimedBeforeReturn
    case remoteEffectPreparedBeforeReturn
    case remoteEffectInvokedBeforeReturn
    case remoteOutcomeAckInsertedBeforePayloadDestroy
}

public typealias GuardianJournalFaultInjector = @Sendable (GuardianJournalFaultPoint) -> Void
