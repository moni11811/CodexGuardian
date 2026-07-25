import Foundation
import Testing
@testable import GuardianCore

@Test func restartRequestSurvivesTheMCPProcessExiting() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let request = RestartRequest(
        recoveryPrompt: "Continue without repeating the stuck tool call.",
        delaySeconds: 2
    )

    try store.enqueue(request)
    let recovered = try store.takePending()

    #expect(recovered == request)
    #expect(try store.takePending() == nil)
}

@Test func unsafeRestartDelaysAreClamped() {
    #expect(RestartRequest(recoveryPrompt: "Resume", delaySeconds: 0).delaySeconds == 1)
    #expect(RestartRequest(recoveryPrompt: "Resume", delaySeconds: 300).delaySeconds == 30)
}

@Test func concurrentChatRequestsDoNotOverwriteEachOther() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let first = RestartRequest(
        threadID: "019f0000-0000-7000-8000-000000000001",
        recoveryPrompt: "Continue first task",
        delaySeconds: 2
    )
    let second = RestartRequest(
        threadID: "019f0000-0000-7000-8000-000000000002",
        recoveryPrompt: "Continue second task",
        delaySeconds: 2
    )

    try store.enqueue(first)
    try store.enqueue(second)

    #expect(try store.takeAllPending() == [first, second])
}
