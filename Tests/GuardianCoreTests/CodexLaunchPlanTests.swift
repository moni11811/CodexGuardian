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
