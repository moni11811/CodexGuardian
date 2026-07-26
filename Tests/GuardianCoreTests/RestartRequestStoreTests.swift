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

@Test func deliveredRestartWaitsForNativeHeartbeatAcknowledgement() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let request = RestartRequest(
        threadID: "exact-thread",
        originToken: "31A25291-BDB6-44EF-AAB8-A95450F99A91",
        continuationAutomationID: "guardian-recovery-test"
    ).withHeartbeatObserved(at: Date(timeIntervalSince1970: 900))
    try store.enqueue(request)
    try store.claimPending(ids: [request.id])
    try store.markClaimAwaitingContinuation(
        id: request.id,
        processIdentifier: 42,
        restartedAt: Date(timeIntervalSince1970: 1_000)
    )

    try store.recoverClaims()

    #expect(try store.peekAllPending().isEmpty)
    #expect(try store.request(originToken: request.originToken!)?.recoveryPhase == .awaitingContinuation)
    #expect(try store.leaseContinuation(originToken: request.originToken!).isDelivery)
    #expect(try store.acknowledgeContinuation(originToken: request.originToken!) == request.id)
    #expect(try store.request(originToken: request.originToken!) == nil)
}

@Test func preparedRecoveryPromptSurvivesUntilHeartbeatDelivery() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let request = RestartRequest(
        threadID: "exact-thread",
        recoveryPrompt: "Fallback",
        originToken: "31A25291-BDB6-44EF-AAB8-A95450F99A91",
        continuationAutomationID: "guardian-recovery-test"
    ).withHeartbeatObserved(at: Date(timeIntervalSince1970: 900))
    try store.enqueue(request)
    try store.claimPending(ids: [request.id])

    try store.updateClaimedRequests([
        request.withRecoveryPrompt("Locally prepared continuation"),
    ])
    try store.markClaimAwaitingContinuation(
        id: request.id,
        processIdentifier: 42,
        restartedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(try store.request(originToken: request.originToken!)?.recoveryPrompt
        == "Locally prepared continuation")
}

@Test func repeatedOriginTokenIsIdempotentAndConflictFailsClosed() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let token = "31A25291-BDB6-44EF-AAB8-A95450F99A91"
    let first = RestartRequest(
        threadID: "exact-thread",
        originToken: token,
        continuationAutomationID: "same-heartbeat"
    )
    let retry = RestartRequest(
        threadID: "exact-thread",
        originToken: token,
        continuationAutomationID: "same-heartbeat"
    )

    let firstID = try store.enqueueUnique(first)
    let retryID = try store.enqueueUnique(retry)

    #expect(firstID == retryID)
    #expect(try store.peekAllPending().count == 1)
    #expect(throws: RestartRequestStoreError.self) {
        try store.enqueueUnique(RestartRequest(
            threadID: "exact-thread",
            originToken: token,
            continuationAutomationID: "different-heartbeat"
        ))
    }
}

@Test func continuationDeliveryUsesAnExpiringSingleOwnerLease() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let token = "31A25291-BDB6-44EF-AAB8-A95450F99A91"
    let request = RestartRequest(
        threadID: "exact-thread",
        originToken: token,
        continuationAutomationID: "guardian-recovery-test"
    ).withHeartbeatObserved(at: Date(timeIntervalSince1970: 900))
    try store.enqueue(request)
    try store.claimPending(ids: [request.id])
    try store.markClaimAwaitingContinuation(
        id: request.id,
        processIdentifier: 42,
        restartedAt: Date(timeIntervalSince1970: 1_000)
    )

    let first = try store.leaseContinuation(
        originToken: token,
        now: Date(timeIntervalSince1970: 1_001),
        leaseDuration: 300
    )
    let overlap = try store.leaseContinuation(
        originToken: token,
        now: Date(timeIntervalSince1970: 1_002),
        leaseDuration: 300
    )
    let retry = try store.leaseContinuation(
        originToken: token,
        now: Date(timeIntervalSince1970: 1_302),
        leaseDuration: 300
    )

    #expect(first.isDelivery)
    #expect(!overlap.isDelivery)
    #expect(retry.isDelivery)
}

@Test func desktopLaunchAloneCannotReleaseContinuation() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = RestartRequestStore(directory: directory)
    let request = RestartRequest(
        threadID: "exact-thread",
        originToken: "31A25291-BDB6-44EF-AAB8-A95450F99A91",
        continuationAutomationID: "guardian-recovery-test"
    )
    try store.enqueue(request)
    try store.claimPending(ids: [request.id])

    #expect(throws: RestartRequestStoreError.self) {
        try store.markClaimAwaitingContinuation(
            id: request.id,
            processIdentifier: 42,
            restartedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
    #expect(try store.request(originToken: request.originToken!)?.recoveryPhase == .claimed)
}
