public enum GuardianManualRestartDenial: Equatable, Sendable {
    case noRecoveryRequest
    case continuationNotArmed
    case authorityTransferred
    case authorityUnprovable
}

public enum GuardianManualRestartDecision: Equatable, Sendable {
    case allowed
    case blocked(GuardianManualRestartDenial)
}

public struct GuardianManualRestartPolicy: Sendable {
    public init() {}

    public func decision(
        requests: [RestartRequest],
        verifiedAutomationIDs: Set<String>,
        authorityFence: GuardianAuthorityFence
    ) -> GuardianManualRestartDecision {
        guard authorityFence.isValid else { return .blocked(.authorityUnprovable) }
        guard authorityFence.owner == .legacy else {
            return .blocked(.authorityTransferred)
        }
        guard !requests.isEmpty else { return .blocked(.noRecoveryRequest) }
        return HardRestartGate().canTerminate(
            requests: requests,
            verifiedAutomationIDs: verifiedAutomationIDs
        ) ? .allowed : .blocked(.continuationNotArmed)
    }
}
