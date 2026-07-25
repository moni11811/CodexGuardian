import Testing
import Foundation
@testable import GuardianCore

@Test func recoveryMustNotLaunchDetachedCodexCLI() {
    let request = RestartRequest(threadID: "thread", recoveryPrompt: "Continue")

    #expect(!CodexResumePlan(request: request).usesDetachedCLI)
}

@Test func recoveryResumesTheExactOriginatingThread() {
    let request = RestartRequest(
        threadID: "019f0000-0000-7000-8000-000000000002",
        recoveryPrompt: "Inspect state and continue",
        delaySeconds: 2
    )

    let plan = CodexResumePlan(request: request)

    #expect(plan.arguments.isEmpty)
    #expect(!plan.usesDetachedCLI)
}

@Test func continuationLauncherRefusesDetachedResumeCommand() throws {
    let request = RestartRequest(
        threadID: "019f0000-0000-7000-8000-000000000002",
        recoveryPrompt: "Continue exact task",
        delaySeconds: 2
    )
    let log = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString).log")
    let launcher = CodexContinuationLauncher()

    #expect(throws: CodexContinuationLauncherError.self) {
        try launcher.start(
            request: request,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            logURL: log
        )
    }
}
