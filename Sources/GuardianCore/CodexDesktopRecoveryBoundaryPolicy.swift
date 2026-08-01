public enum CodexDesktopRecoveryBoundaryDecision: Equatable, Sendable {
    case launchBeforeNativeRecovery
    case continueNativeRecovery
    case automaticRestartAllowed
    case humanForceRequired
}

public struct CodexDesktopRecoveryBoundaryPolicy: Sendable {
    public init() {}

    public func decision(
        desktopIsRunning: Bool,
        nativeDeliveryFailed: Bool,
        inventoryIsAuthoritativeAndSafe: Bool
    ) -> CodexDesktopRecoveryBoundaryDecision {
        guard desktopIsRunning else { return .launchBeforeNativeRecovery }
        guard nativeDeliveryFailed else { return .continueNativeRecovery }
        return inventoryIsAuthoritativeAndSafe
            ? .automaticRestartAllowed
            : .humanForceRequired
    }
}
