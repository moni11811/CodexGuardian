import Foundation
import Testing
@testable import GuardianCore

struct GuardianRecoveryDispatchPolicyTests {
    @Test func nativeRecoveryWinsWithoutEnteringHardRestartAuthorityGate() {
        let hard = RestartRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            requestedAt: Date(timeIntervalSince1970: 1),
            threadID: "hard",
            originToken: UUID().uuidString,
            continuationAutomationID: "heartbeat"
        )
        let native = RestartRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            requestedAt: Date(timeIntervalSince1970: 2),
            threadID: "native",
            originToken: UUID().uuidString,
            requestMode: .nativeFirst
        )

        #expect(GuardianRecoveryDispatchPolicy().decision(
            pendingRequests: [hard, native]
        ) == .native(native))
    }

    @Test func hardRequestsRemainBatchedWhenNoNativeRecoveryExists() {
        let first = RestartRequest(
            requestedAt: Date(timeIntervalSince1970: 2),
            threadID: "second",
            originToken: UUID().uuidString,
            continuationAutomationID: "heartbeat-2"
        )
        let second = RestartRequest(
            requestedAt: Date(timeIntervalSince1970: 1),
            threadID: "first",
            originToken: UUID().uuidString,
            continuationAutomationID: "heartbeat-1"
        )

        #expect(GuardianRecoveryDispatchPolicy().decision(
            pendingRequests: [first, second]
        ) == .hardRestart([second, first]))
        #expect(GuardianRecoveryDispatchPolicy().decision(
            pendingRequests: []
        ) == .idle)
    }
}
