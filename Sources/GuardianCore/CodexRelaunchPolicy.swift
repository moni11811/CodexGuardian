public struct CodexRelaunchPolicy: Sendable {
    public init() {}

    public func isRecovered(openSucceeded: Bool, applicationIsRunning: Bool) -> Bool {
        openSucceeded && applicationIsRunning
    }

    public func didRestart(
        previousProcessIDs: Set<Int32>,
        currentProcessIDs: Set<Int32>
    ) -> Bool {
        !currentProcessIDs.subtracting(previousProcessIDs).isEmpty
    }
}
