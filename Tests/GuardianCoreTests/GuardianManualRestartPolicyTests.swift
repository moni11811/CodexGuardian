import Foundation
import Testing
@testable import GuardianCore

@Test func manualForceNeverBypassesArmedContinuationProof() {
    let policy = GuardianManualRestartPolicy()
    let unarmed = RestartRequest(delaySeconds: 1)
    #expect(policy.decision(
        requests: [],
        verifiedAutomationIDs: [],
        authorityFence: legacyAuthorityFence()
    )
        == .blocked(.noRecoveryRequest))
    #expect(policy.decision(
        requests: [unarmed],
        verifiedAutomationIDs: [],
        authorityFence: legacyAuthorityFence()
    )
        == .blocked(.continuationNotArmed))

    let armed = RestartRequest(
        threadID: "exact-thread",
        originToken: "31A25291-BDB6-44EF-AAB8-A95450F99A91",
        continuationAutomationID: "guardian-heartbeat"
    ).withHeartbeatObserved(at: Date(timeIntervalSince1970: 1_000))
    #expect(policy.decision(
        requests: [armed],
        verifiedAutomationIDs: ["guardian-heartbeat"],
        authorityFence: legacyAuthorityFence()
    ) == .allowed)
}

@Test func manualForceCannotOverrideCommittedDaemonAuthority() {
    let armed = RestartRequest(
        threadID: "exact-thread",
        originToken: "26D91160-A9EC-4C26-B19D-4B4C5C3BF015",
        continuationAutomationID: "guardian-heartbeat"
    ).withHeartbeatObserved(at: Date(timeIntervalSince1970: 1_000))
    let daemonFence = GuardianAuthorityFence(
        phase: .daemonAuthoritative,
        epoch: 1,
        proof: GuardianAuthorityCutoverProof(
            desktopControlEvidenceID: "gate0",
            observerComparisonEvidenceID: "comparison",
            deploymentID: "deployment",
            daemonGeneration: 7
        ),
        updatedAt: Date(timeIntervalSince1970: 1_001)
    )

    #expect(GuardianManualRestartPolicy().decision(
        requests: [armed],
        verifiedAutomationIDs: ["guardian-heartbeat"],
        authorityFence: daemonFence
    ) == .blocked(.authorityTransferred))
}

private func legacyAuthorityFence() -> GuardianAuthorityFence {
    GuardianAuthorityFence(
        phase: .legacyAuthoritative,
        epoch: 0,
        proof: nil,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}
