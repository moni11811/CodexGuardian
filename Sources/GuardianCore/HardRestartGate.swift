public struct HardRestartGate: Sendable {
    public init() {}

    public func canTerminate(
        requests: [RestartRequest],
        verifiedAutomationIDs: Set<String>
    ) -> Bool {
        let requestedAutomationIDs = Set(requests.compactMap(\.continuationAutomationID))
        return !requests.isEmpty
            && requestedAutomationIDs.count == requests.count
            && requests.allSatisfy { request in
            guard request.automaticContinuationIsArmed,
                  request.heartbeatObservedAt != nil,
                  let automationID = request.continuationAutomationID else { return false }
            return verifiedAutomationIDs.contains(automationID)
        }
    }
}
