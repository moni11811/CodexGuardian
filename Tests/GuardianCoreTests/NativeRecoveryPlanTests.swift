import Testing
@testable import GuardianCore

@Test func nativeRecoveryTargetsExactDesktopThreadWithoutRestart() {
    let plan = NativeRecoveryPlan(
        threadID: "019f0000-0000-7000-8000-000000000002",
        recoveryPrompt: "Inspect current state, change route, and continue."
    )

    #expect(plan.threadID == "019f0000-0000-7000-8000-000000000002")
    #expect(plan.recoveryPrompt == "Inspect current state, change route, and continue.")
    #expect(!plan.restartsDesktop)
}
