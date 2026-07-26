import Foundation
import Testing
@testable import GuardianCore

@Test func activeParallelTaskBlocksRestart() {
    let requestedAt = Date(timeIntervalSince1970: 1_000)
    let request = RestartRequest(
        requestedAt: requestedAt,
        threadID: "stuck-task",
        recoveryPrompt: "Continue"
    )
    let activities = [
        CodexTaskActivity(
            threadID: "stuck-task",
            modifiedAt: requestedAt.addingTimeInterval(2),
            state: .idle
        ),
        CodexTaskActivity(
            threadID: "other-working-task",
            modifiedAt: requestedAt.addingTimeInterval(8),
            state: .active
        ),
    ]

    let decision = RestartQuiescencePolicy().decision(
        requests: [request],
        activities: activities,
        now: requestedAt.addingTimeInterval(20)
    )

    #expect(decision == .waitForTasks(["other-working-task"]))
}

@Test func requestedStuckTaskDoesNotBlockItsOwnRecovery() {
    let requestedAt = Date(timeIntervalSince1970: 1_000)
    let originToken = "31A25291-BDB6-44EF-AAB8-A95450F99A91"
    let request = RestartRequest(
        requestedAt: requestedAt,
        threadID: "stuck-task",
        recoveryPrompt: "Continue",
        originToken: originToken,
        continuationAutomationID: "guardian-recovery-test"
    ).withHeartbeatObserved(at: requestedAt)
    let activity = CodexTaskActivity(
        threadID: "stuck-task",
        modifiedAt: requestedAt,
        state: .active,
        activeRecoveryOriginToken: originToken
    )

    let decision = RestartQuiescencePolicy(quietPeriod: 5).decision(
        requests: [request],
        activities: [activity],
        now: requestedAt.addingTimeInterval(20)
    )

    #expect(decision == .restart)
}

@Test func resumedWorkInRequestedTaskBlocksRestart() {
    let requestedAt = Date(timeIntervalSince1970: 1_000)
    let request = RestartRequest(
        requestedAt: requestedAt,
        threadID: "stuck-task",
        recoveryPrompt: "Continue",
        originToken: "31A25291-BDB6-44EF-AAB8-A95450F99A91",
        continuationAutomationID: "guardian-recovery-test"
    ).withHeartbeatObserved(at: requestedAt.addingTimeInterval(1))
    let resumedWork = CodexTaskActivity(
        threadID: "stuck-task",
        modifiedAt: requestedAt.addingTimeInterval(20),
        state: .active
    )

    let decision = RestartQuiescencePolicy(quietPeriod: 5).decision(
        requests: [request],
        activities: [resumedWork],
        now: requestedAt.addingTimeInterval(40)
    )

    #expect(decision == .waitForTasks(["stuck-task"]))
}

@Test func recentlyFinishedTasksNeedAQuietWindow() {
    let requestedAt = Date(timeIntervalSince1970: 1_000)
    let request = RestartRequest(requestedAt: requestedAt, threadID: "stuck-task")
    let activity = CodexTaskActivity(
        threadID: "stuck-task",
        modifiedAt: requestedAt.addingTimeInterval(18),
        state: .idle
    )

    let decision = RestartQuiescencePolicy(quietPeriod: 5).decision(
        requests: [request],
        activities: [activity],
        now: requestedAt.addingTimeInterval(20)
    )

    #expect(decision == .waitForQuietPeriod)
}

@Test func guardianRestartsOnlyAfterAllTasksAreIdleAndQuiet() {
    let requestedAt = Date(timeIntervalSince1970: 1_000)
    let request = RestartRequest(requestedAt: requestedAt, threadID: "stuck-task")
    let activities = [
        CodexTaskActivity(
            threadID: "stuck-task",
            modifiedAt: requestedAt.addingTimeInterval(3),
            state: .idle
        ),
        CodexTaskActivity(
            threadID: "other-task",
            modifiedAt: requestedAt.addingTimeInterval(4),
            state: .idle
        ),
    ]

    let decision = RestartQuiescencePolicy(quietPeriod: 5).decision(
        requests: [request],
        activities: activities,
        now: requestedAt.addingTimeInterval(20)
    )

    #expect(decision == .restart)
}

@Test func missingOriginActivityFailsClosed() {
    let requestedAt = Date(timeIntervalSince1970: 1_000)
    let request = RestartRequest(requestedAt: requestedAt, threadID: "unknown-task")

    let decision = RestartQuiescencePolicy().decision(
        requests: [request],
        activities: [],
        now: requestedAt.addingTimeInterval(60)
    )

    #expect(decision == .waitForTasks(["unknown-task"]))
}

@Test func everyActivityPassedByTheProcessLifetimeScanCanBlockRestart() {
    let requestedAt = Date(timeIntervalSince1970: 100_000)
    let request = RestartRequest(requestedAt: requestedAt, threadID: "stuck-task")
    let activities = [
        CodexTaskActivity(
            threadID: "stuck-task",
            modifiedAt: requestedAt,
            state: .idle
        ),
        CodexTaskActivity(
            threadID: "long-running-task",
            modifiedAt: requestedAt.addingTimeInterval(-(13 * 60 * 60)),
            state: .active
        ),
    ]

    let decision = RestartQuiescencePolicy().decision(
        requests: [request],
        activities: activities,
        now: requestedAt.addingTimeInterval(60)
    )

    #expect(decision == .waitForTasks(["long-running-task"]))
}

@Test func rolloutScannerDistinguishesWorkingAndFinishedTasks() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let activeURL = root.appending(path: "active.jsonl")
    let idleURL = root.appending(path: "idle.jsonl")
    try """
    {"type":"session_meta","payload":{"id":"active-task"}}
    {"type":"response_item","payload":{"type":"custom_tool_call","status":"completed"}}
    """.write(to: activeURL, atomically: true, encoding: .utf8)
    try """
    {"type":"session_meta","payload":{"id":"idle-task"}}
    {"type":"event_msg","payload":{"type":"task_complete"}}
    """.write(to: idleURL, atomically: true, encoding: .utf8)

    let scan = try CodexTaskActivityScanner(sessionsRoot: root).scan()
    let states = Dictionary(uniqueKeysWithValues: scan.activities.map { ($0.threadID, $0.state) })

    #expect(states["active-task"] == .active)
    #expect(states["idle-task"] == .idle)
}

@Test func rolloutScannerIdentifiesOnlyTheActiveRecoveryHeartbeat() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let token = "31A25291-BDB6-44EF-AAB8-A95450F99A91"
    let heartbeatURL = root.appending(path: "heartbeat.jsonl")
    let resumedURL = root.appending(path: "resumed.jsonl")
    try """
    {"type":"session_meta","payload":{"id":"heartbeat-task"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"<heartbeat> Codex Guardian hard-recovery heartbeat \(token). Call recovery_tick now. </heartbeat>"}}
    {"type":"response_item","payload":{"type":"reasoning"}}
    """.write(to: heartbeatURL, atomically: true, encoding: .utf8)
    try """
    {"type":"session_meta","payload":{"id":"resumed-task"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"<heartbeat> Codex Guardian hard-recovery heartbeat \(token). Call recovery_tick now. </heartbeat>"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"Do useful project work now."}}
    {"type":"response_item","payload":{"type":"reasoning"}}
    """.write(to: resumedURL, atomically: true, encoding: .utf8)

    let scan = try CodexTaskActivityScanner(sessionsRoot: root).scan()
    let activities = Dictionary(uniqueKeysWithValues: scan.activities.map { ($0.threadID, $0) })

    #expect(activities["heartbeat-task"]?.activeRecoveryOriginToken == token)
    #expect(activities["resumed-task"]?.activeRecoveryOriginToken == nil)
}

@Test func partialTailAfterCompletionIsStillActive() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rollout = root.appending(path: "partial.jsonl")
    try """
    {"type":"session_meta","payload":{"id":"writing-task"}}
    {"type":"event_msg","payload":{"type":"task_complete"}}
    {"type":"response_item"
    """.write(to: rollout, atomically: true, encoding: .utf8)

    let scan = try CodexTaskActivityScanner(sessionsRoot: root).scan()

    #expect(scan.activities.first?.state == .active)
}

@Test func scannerReportsWhenItsSafetyViewIsTruncated() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 1...2 {
        let rollout = root.appending(path: "\(index).jsonl")
        try """
        {"type":"session_meta","payload":{"id":"task-\(index)"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """.write(to: rollout, atomically: true, encoding: .utf8)
    }

    let scan = try CodexTaskActivityScanner(
        sessionsRoot: root,
        maximumFiles: 1
    ).scan()

    #expect(!scan.isComplete)
    #expect(scan.activities.count == 1)
}
