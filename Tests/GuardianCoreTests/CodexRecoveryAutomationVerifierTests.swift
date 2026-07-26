import Foundation
import Testing
@testable import GuardianCore

@Test func exactActiveHeartbeatArmsHardRecovery() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let automationID = "guardian-recovery-test"
    let threadID = "019f0000-0000-7000-8000-000000000002"
    let originToken = "31A25291-BDB6-44EF-AAB8-A95450F99A91"
    try writeAutomation(
        root: root,
        id: automationID,
        threadID: threadID,
        status: "ACTIVE",
        prompt: "Call recovery_tick with \(originToken)"
    )

    let verifier = CodexRecoveryAutomationVerifier(automationsDirectory: root)

    #expect(try verifier.isArmed(
        automationID: automationID,
        threadID: threadID,
        originToken: originToken
    ))
}

@Test func pausedOrWrongThreadHeartbeatFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let originToken = "31A25291-BDB6-44EF-AAB8-A95450F99A91"
    try writeAutomation(
        root: root,
        id: "paused-recovery",
        threadID: "right-thread",
        status: "PAUSED",
        prompt: "Call recovery_tick with \(originToken)"
    )
    try writeAutomation(
        root: root,
        id: "wrong-thread",
        threadID: "other-thread",
        status: "ACTIVE",
        prompt: "Call recovery_tick with \(originToken)"
    )
    let verifier = CodexRecoveryAutomationVerifier(automationsDirectory: root)

    #expect(try !verifier.isArmed(
        automationID: "paused-recovery",
        threadID: "right-thread",
        originToken: originToken
    ))
    #expect(try !verifier.isArmed(
        automationID: "wrong-thread",
        threadID: "right-thread",
        originToken: originToken
    ))
    #expect(try verifier.automationExists(automationID: "paused-recovery"))
    #expect(try !verifier.automationExists(automationID: "already-deleted"))
}

@Test func malformedHeartbeatPromptOrScheduleFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let token = "31A25291-BDB6-44EF-AAB8-A95450F99A91"
    try writeAutomation(
        root: root,
        id: "wrong-prompt",
        threadID: "exact-thread",
        status: "ACTIVE",
        prompt: "Merely contains \(token)",
        rrule: "RRULE:FREQ=MINUTELY;INTERVAL=1"
    )
    try writeAutomation(
        root: root,
        id: "wrong-schedule",
        threadID: "exact-thread",
        status: "ACTIVE",
        prompt: "Call recovery_tick with \(token)",
        rrule: "RRULE:FREQ=DAILY;INTERVAL=1"
    )
    let verifier = CodexRecoveryAutomationVerifier(automationsDirectory: root)

    #expect(try !verifier.isArmed(
        automationID: "wrong-prompt",
        threadID: "exact-thread",
        originToken: token
    ))
    #expect(try !verifier.isArmed(
        automationID: "wrong-schedule",
        threadID: "exact-thread",
        originToken: token
    ))
}

@Test func automationIdentifierCannotEscapeItsStateDirectory() throws {
    let parent = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appending(path: "automations", directoryHint: .isDirectory)
    let token = "31A25291-BDB6-44EF-AAB8-A95450F99A91"
    try writeAutomation(
        root: root,
        id: "..",
        threadID: "exact-thread",
        status: "ACTIVE",
        prompt: "Call recovery_tick with \(token)"
    )
    let verifier = CodexRecoveryAutomationVerifier(automationsDirectory: root)

    #expect(try !verifier.isArmed(
        automationID: "..",
        threadID: "exact-thread",
        originToken: token
    ))
}

private func writeAutomation(
    root: URL,
    id: String,
    threadID: String,
    status: String,
    prompt: String,
    rrule: String = "RRULE:FREQ=MINUTELY;INTERVAL=1"
) throws {
    let directory = root.appending(path: id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = """
    version = 1
    id = "\(id)"
    kind = "heartbeat"
    status = "\(status)"
    target_thread_id = "\(threadID)"
    prompt = "\(prompt)"
    rrule = "\(rrule)"
    """
    try Data(config.utf8).write(to: directory.appending(path: "automation.toml"))
}
