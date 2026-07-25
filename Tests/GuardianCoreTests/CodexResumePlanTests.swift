import Testing
import Foundation
@testable import GuardianCore

@Test func recoveryResumesTheExactOriginatingThread() {
    let request = RestartRequest(
        threadID: "019f0000-0000-7000-8000-000000000002",
        recoveryPrompt: "Inspect state and continue",
        delaySeconds: 2
    )

    let plan = CodexResumePlan(request: request)

    #expect(plan.arguments == [
        "exec", "--skip-git-repo-check", "resume", "--json",
        "019f0000-0000-7000-8000-000000000002",
        "Inspect state and continue",
    ])
}

@Test func continuationLauncherActuallyInvokesResumeCommand() throws {
    let request = RestartRequest(
        threadID: "019f0000-0000-7000-8000-000000000002",
        recoveryPrompt: "Continue exact task",
        delaySeconds: 2
    )
    let log = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString).log")
    let launcher = CodexContinuationLauncher()

    let process = try launcher.start(
        request: request,
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        logURL: log
    )
    process.waitUntilExit()

    let output = try String(contentsOf: log, encoding: .utf8)
    #expect(process.terminationStatus == 0)
    #expect(output.contains("exec --skip-git-repo-check resume --json 019f0000-0000-7000-8000-000000000002 Continue exact task"))
}
