public struct CodexRelaunchPolicy: Sendable {
    public init() {}

    public func isRecovered(openSucceeded: Bool, applicationIsRunning: Bool) -> Bool {
        openSucceeded && applicationIsRunning
    }
}
