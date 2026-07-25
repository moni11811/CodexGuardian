public struct CodexRecoveryStartupPolicy: Sendable {
    public let continuationDelaySeconds = 5

    public init() {}

    public func shouldStartContinuation(desktopIsRunning: Bool) -> Bool {
        desktopIsRunning
    }
}
