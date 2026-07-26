import Foundation
import Testing
@testable import GuardianCore

@Test func hardRestartGateRequiresObservedAndCurrentlyVerifiedHeartbeat() {
    let base = RestartRequest(
        threadID: "exact-thread",
        originToken: "31A25291-BDB6-44EF-AAB8-A95450F99A91",
        continuationAutomationID: "guardian-recovery-test"
    )
    let gate = HardRestartGate()

    #expect(!gate.canTerminate(
        requests: [base],
        verifiedAutomationIDs: ["guardian-recovery-test"]
    ))

    let observed = base.withHeartbeatObserved(at: Date(timeIntervalSince1970: 1_000))
    #expect(!gate.canTerminate(requests: [observed], verifiedAutomationIDs: []))
    #expect(gate.canTerminate(
        requests: [observed],
        verifiedAutomationIDs: ["guardian-recovery-test"]
    ))
}
