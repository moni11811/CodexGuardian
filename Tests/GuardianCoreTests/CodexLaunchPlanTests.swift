import Testing
@testable import GuardianCore

@Test func codexRelaunchFallsBackToInstalledChatGPTBundle() {
    let plan = CodexLaunchPlan(bundleIdentifier: "com.openai.codex")

    #expect(plan.bundleIdentifier == "com.openai.codex")
    #expect(plan.fallbackApplicationPaths.contains("/Applications/ChatGPT.app"))
}

@Test func successfulOpenWithoutRunningCodexIsNotRecovery() {
    let policy = CodexRelaunchPolicy()

    #expect(!policy.isRecovered(openSucceeded: true, applicationIsRunning: false))
    #expect(policy.isRecovered(openSucceeded: true, applicationIsRunning: true))
}

@Test func continuationWaitsForVerifiedDesktopRelaunch() {
    let policy = CodexRecoveryStartupPolicy()

    #expect(!policy.shouldStartContinuation(desktopIsRunning: false))
    #expect(policy.shouldStartContinuation(desktopIsRunning: true))
}

@Test func recoveryDeepLinkTargetsExactDesktopThread() {
    let link = CodexThreadDeepLink(threadID: "019f0000-0000-7000-8000-000000000002")

    #expect(link.url.absoluteString == "codex://threads/019f0000-0000-7000-8000-000000000002")
}
