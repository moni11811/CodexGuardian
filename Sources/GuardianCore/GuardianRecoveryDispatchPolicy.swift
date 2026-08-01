import Foundation

public enum GuardianRecoveryDispatchDecision: Equatable, Sendable {
    case idle
    case native(RestartRequest)
    case hardRestart([RestartRequest])
}

public struct GuardianRecoveryDispatchPolicy: Sendable {
    public init() {}

    public func decision(
        pendingRequests: [RestartRequest]
    ) -> GuardianRecoveryDispatchDecision {
        let ordered = pendingRequests.sorted {
            if $0.requestedAt == $1.requestedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.requestedAt < $1.requestedAt
        }
        if let native = ordered.first(where: { $0.requestMode == .nativeFirst }) {
            return .native(native)
        }
        return ordered.isEmpty ? .idle : .hardRestart(ordered)
    }
}
