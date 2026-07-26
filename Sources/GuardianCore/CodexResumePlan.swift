public enum CodexContinuationDeliveryMode: Equatable, Sendable {
    case nativeRecoveryHeartbeat
}

public struct CodexResumePlan: Equatable, Sendable {
    public let arguments: [String]
    public let usesDetachedCLI: Bool
    public let deliveryMode: CodexContinuationDeliveryMode
    public let requiresManualSend: Bool

    public init(request: RestartRequest) {
        arguments = []
        usesDetachedCLI = false
        deliveryMode = .nativeRecoveryHeartbeat
        requiresManualSend = false
    }
}
