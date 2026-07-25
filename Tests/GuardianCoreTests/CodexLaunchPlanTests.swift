import Testing
@testable import GuardianCore

@Test func codexRelaunchFallsBackToInstalledChatGPTBundle() {
    let plan = CodexLaunchPlan(bundleIdentifier: "com.openai.codex")

    #expect(plan.bundleIdentifier == "com.openai.codex")
    #expect(plan.fallbackApplicationPaths.contains("/Applications/ChatGPT.app"))
}
