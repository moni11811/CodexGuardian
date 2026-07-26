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
    let firstRequestedAt = Date(timeIntervalSince1970: 1_000)
    let first = RestartRequest(
        requestedAt: firstRequestedAt,
        threadID: "019f0000-0000-7000-8000-000000000001",
        recoveryPrompt: "Continue first task",
        delaySeconds: 2
    )
    let second = RestartRequest(
        requestedAt: firstRequestedAt.addingTimeInterval(1),
        threadID: "019f0000-0000-7000-8000-000000000002",
        recoveryPrompt: "Continue second task",
        delaySeconds: 2
    )

    try store.enqueue(first)
    try store.enqueue(second)

    #expect(try store.takeAllPending() == [first, second])
}

@Test func pendingRequestsCanBeObservedWithoutRemovingThem() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let request = RestartRequest(threadID: "working-task")

    try store.enqueue(request)

    #expect(try store.peekAllPending() == [request])
    #expect(try store.takeAllPending() == [request])
}

@Test func claimingAReadySnapshotLeavesNewerRequestsQueued() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let first = RestartRequest(
        requestedAt: Date(timeIntervalSince1970: 1_000),
        threadID: "first-task"
    )
    let later = RestartRequest(
        requestedAt: Date(timeIntervalSince1970: 1_001),
        threadID: "later-task"
    )
    try store.enqueue(first)
    try store.enqueue(later)

    try store.claimPending(ids: [first.id])

    #expect(try store.peekAllPending() == [later])
}

@Test func unfinishedClaimsRecoverAfterGuardianRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let request = RestartRequest(threadID: "claimed-task")
    try store.enqueue(request)
    try store.claimPending(ids: [request.id])

    let relaunchedStore = RestartRequestStore(directory: directory)
    try relaunchedStore.recoverClaims()

    #expect(try relaunchedStore.peekAllPending() == [request])
}
