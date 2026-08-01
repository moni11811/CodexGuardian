import Foundation
import Testing
@testable import GuardianCore

@Test func correlatedProgressExtendsSoftDeadlineWithoutMovingHardCap() throws {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    var tracker = CodexAppServerRecoveryLivenessTracker(
        policy: CodexAppServerRecoveryLivenessPolicy(
            initialSilenceTimeout: 60,
            startupProgressTimeout: 90,
            hookProgressTimeout: 180,
            turnProgressTimeout: 120,
            hardTimeout: 300
        ),
        startedAt: startedAt
    )
    let startup = Data(#"{"method":"mcpServer/startupStatus/updated","params":{"threadId":"thread-gate0","name":"context-mode","status":"starting"}}"#.utf8)
    let otherTask = Data(#"{"method":"mcpServer/startupStatus/updated","params":{"threadId":"other","name":"context-mode","status":"ready"}}"#.utf8)
    let hook = Data(#"{"method":"hook/started","params":{"threadId":"thread-gate0","turnId":"turn-1","run":{"id":"hook-1"}}}"#.utf8)

    #expect(tracker.deadline == startedAt.addingTimeInterval(60))
    #expect(try tracker.observe(
        notification: startup,
        expectedThreadID: "thread-gate0",
        at: startedAt.addingTimeInterval(50)
    ))
    #expect(tracker.deadline == startedAt.addingTimeInterval(140))

    #expect(!(try tracker.observe(
        notification: startup,
        expectedThreadID: "thread-gate0",
        at: startedAt.addingTimeInterval(100)
    )))
    #expect(!(try tracker.observe(
        notification: otherTask,
        expectedThreadID: "thread-gate0",
        at: startedAt.addingTimeInterval(100)
    )))
    #expect(tracker.deadline == startedAt.addingTimeInterval(140))

    #expect(try tracker.observe(
        notification: hook,
        expectedThreadID: "thread-gate0",
        at: startedAt.addingTimeInterval(130)
    ))
    #expect(tracker.deadline == startedAt.addingTimeInterval(300))
    #expect(tracker.hardDeadline == startedAt.addingTimeInterval(300))
}

@Test func recoveryCoordinatorCompletesOneExactThreePhaseLoop() throws {
    let threadID = "thread-gate0"
    let token = try #require(UUID(uuidString: "3D27C100-9A65-4C32-BE13-703D89D0E829"))
    let clientMessageID = CodexAppServerRecoveryProtocol.clientMessageID(
        originToken: token,
        generation: 3
    )
    let transport = ScriptedRecoveryTransport(
        responses: [
            Data(#"{"id":1,"result":{"userAgent":"test"}}"#.utf8),
            Data(#"{"id":2,"result":{"thread":{"id":"thread-gate0","turns":[]}}}"#.utf8),
            Data(#"{"id":3,"result":{"thread":{"id":"thread-gate0","turns":[]}}}"#.utf8),
            Data(#"{"id":4,"result":{"turn":{"id":"turn-new","status":"inProgress","items":[]}}}"#.utf8),
            Data("""
            {"id":5,"result":{"thread":{"id":"thread-gate0","turns":[
              {"id":"turn-new","items":[
                {"type":"userMessage","id":"item-user","clientId":"\(clientMessageID)"},
                {"type":"agentMessage","id":"item-agent","text":"continued"}
              ]}
            ]}}}
            """.utf8),
        ],
        notifications: [
            Data(#"{"method":"turn/completed","params":{"threadId":"other","turn":{"id":"turn-new","status":"completed","items":[]}}}"#.utf8),
            Data(#"{"method":"turn/completed","params":{"threadId":"thread-gate0","turn":{"id":"turn-new","status":"completed","items":[]}}}"#.utf8),
        ]
    )

    let outcome = try CodexAppServerRecoveryCoordinator().recover(
        threadID: threadID,
        prompt: "Continue exact task",
        originToken: token,
        generation: 3,
        transport: transport,
        deadline: Date().addingTimeInterval(5)
    )

    #expect(outcome == .completed(CodexAppServerRecoveryDelivery(
        threadID: threadID,
        turnID: "turn-new",
        clientMessageID: clientMessageID,
        userMessageItemID: "item-user"
    )))
    #expect(transport.requestMethods() == [
        "initialize",
        "thread/resume",
        "thread/read",
        "turn/start",
        "thread/read",
    ])
    #expect(transport.notificationMethods() == ["initialized"])
}

@Test func recoveryCoordinatorUsesProgressAwareReceiveDeadlines() throws {
    let startedAt = Date()
    let threadID = "thread-gate0"
    let token = try #require(UUID(uuidString: "3D27C100-9A65-4C32-BE13-703D89D0E829"))
    let clientMessageID = CodexAppServerRecoveryProtocol.clientMessageID(
        originToken: token,
        generation: 3
    )
    let transport = ScriptedRecoveryTransport(
        responses: [
            Data(#"{"id":1,"result":{"userAgent":"test"}}"#.utf8),
            Data(#"{"id":2,"result":{"thread":{"id":"thread-gate0","turns":[]}}}"#.utf8),
            Data(#"{"id":3,"result":{"thread":{"id":"thread-gate0","turns":[]}}}"#.utf8),
            Data(#"{"id":4,"result":{"turn":{"id":"turn-new","status":"inProgress","items":[]}}}"#.utf8),
            Data("""
            {"id":5,"result":{"thread":{"id":"thread-gate0","turns":[
              {"id":"turn-new","items":[
                {"type":"userMessage","id":"item-user","clientId":"\(clientMessageID)"}
              ]}
            ]}}}
            """.utf8),
        ],
        notifications: [
            Data(#"{"method":"hook/started","params":{"threadId":"thread-gate0","turnId":"turn-new","run":{"id":"hook-1"}}}"#.utf8),
            Data(#"{"method":"turn/completed","params":{"threadId":"thread-gate0","turn":{"id":"turn-new","status":"completed","items":[]}}}"#.utf8),
        ]
    )
    let policy = CodexAppServerRecoveryLivenessPolicy(
        initialSilenceTimeout: 20,
        startupProgressTimeout: 30,
        hookProgressTimeout: 180,
        turnProgressTimeout: 60,
        hardTimeout: 300
    )

    _ = try CodexAppServerRecoveryCoordinator().recover(
        threadID: threadID,
        prompt: "Continue exact task",
        originToken: token,
        generation: 3,
        transport: transport,
        deadline: startedAt.addingTimeInterval(300),
        livenessPolicy: policy
    )

    let receiveDeadlines = transport.receiveDeadlines()
    #expect(receiveDeadlines.count == 2)
    #expect(receiveDeadlines[0] < startedAt.addingTimeInterval(30))
    #expect(receiveDeadlines[1] > startedAt.addingTimeInterval(170))
    #expect(receiveDeadlines[1] <= startedAt.addingTimeInterval(300))
}

@Test func recoveryCoordinatorDoesNotResendAnExistingClientMessage() throws {
    let token = try #require(UUID(uuidString: "3D27C100-9A65-4C32-BE13-703D89D0E829"))
    let clientID = CodexAppServerRecoveryProtocol.clientMessageID(
        originToken: token,
        generation: 3
    )
    let readResponse = Data("""
    {"id":3,"result":{"thread":{"id":"thread-gate0","turns":[
      {"id":"turn-existing","items":[
        {"type":"userMessage","id":"item-existing","clientId":"\(clientID)"}
      ]}
    ]}}}
    """.utf8)
    let transport = ScriptedRecoveryTransport(
        responses: [
            Data(#"{"id":1,"result":{"userAgent":"test"}}"#.utf8),
            Data(#"{"id":2,"result":{"thread":{"id":"thread-gate0","turns":[]}}}"#.utf8),
            readResponse,
        ],
        notifications: []
    )

    let outcome = try CodexAppServerRecoveryCoordinator().recover(
        threadID: "thread-gate0",
        prompt: "Continue exact task",
        originToken: token,
        generation: 3,
        transport: transport,
        deadline: Date().addingTimeInterval(5)
    )

    #expect(outcome == .alreadySubmitted(CodexAppServerRecoveryDelivery(
        threadID: "thread-gate0",
        turnID: "turn-existing",
        clientMessageID: clientID,
        userMessageItemID: "item-existing"
    )))
    #expect(transport.requestMethods() == [
        "initialize",
        "thread/resume",
        "thread/read",
    ])
}

private final class ScriptedRecoveryTransport: @unchecked Sendable,
    CodexAppServerRecoveryTransport {
    private let lock = NSLock()
    private var responses: [Data]
    private var notifications: [Data]
    private var requests: [Data] = []
    private var sentNotifications: [Data] = []
    private var recordedReceiveDeadlines: [Date] = []

    init(responses: [Data], notifications: [Data]) {
        self.responses = responses
        self.notifications = notifications
    }

    func exchange(request: Data, deadline: Date) throws -> Data {
        try lock.withLock {
            requests.append(request)
            guard !responses.isEmpty else { throw ScriptedTransportError.exhausted }
            return responses.removeFirst()
        }
    }

    func send(notification: Data, deadline: Date) throws {
        lock.withLock { sentNotifications.append(notification) }
    }

    func receive(deadline: Date) throws -> Data {
        try lock.withLock {
            recordedReceiveDeadlines.append(deadline)
            guard !notifications.isEmpty else { throw ScriptedTransportError.exhausted }
            return notifications.removeFirst()
        }
    }

    func requestMethods() -> [String] {
        lock.withLock { requests.compactMap(Self.method) }
    }

    func notificationMethods() -> [String] {
        lock.withLock { sentNotifications.compactMap(Self.method) }
    }

    func receiveDeadlines() -> [Date] {
        lock.withLock { recordedReceiveDeadlines }
    }

    private static func method(_ data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["method"] as? String
    }
}

private enum ScriptedTransportError: Error {
    case exhausted
}
