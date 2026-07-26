import Foundation

public struct CodexRecoveryStartupPolicy: Sendable {
    public let continuationDelaySeconds: TimeInterval = 15

    public init() {}

    public func shouldStartContinuation(
        desktopIsRunning: Bool,
        appServerIsRunning: Bool,
        settledFor: TimeInterval
    ) -> Bool {
        desktopIsRunning
            && appServerIsRunning
            && settledFor >= continuationDelaySeconds
    }
}

public struct CodexRecoveryStartupTracker: Sendable {
    public let policy: CodexRecoveryStartupPolicy
    private var appServerObservedAt: Date?

    public init(policy: CodexRecoveryStartupPolicy = CodexRecoveryStartupPolicy()) {
        self.policy = policy
    }

    public mutating func shouldStartContinuation(
        desktopIsRunning: Bool,
        appServerIsRunning: Bool,
        now: Date = Date()
    ) -> Bool {
        guard desktopIsRunning, appServerIsRunning else {
            appServerObservedAt = nil
            return false
        }
        if appServerObservedAt == nil {
            appServerObservedAt = now
        }
        return policy.shouldStartContinuation(
            desktopIsRunning: desktopIsRunning,
            appServerIsRunning: appServerIsRunning,
            settledFor: max(0, now.timeIntervalSince(appServerObservedAt ?? now))
        )
    }
}
