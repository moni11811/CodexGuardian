import Foundation

@main
enum Gate0ProtocolSelfTest {
    static func main() throws {
        let threadID = "thread-gate0"
        let token = UUID(uuidString: "3D27C100-9A65-4C32-BE13-703D89D0E829")!
        let clientID = CodexAppServerRecoveryProtocol.clientMessageID(
            originToken: token,
            generation: 9
        )
        try require(clientID == "guardian:3d27c100-9a65-4c32-be13-703d89d0e829:9")

        let resumeRequest = try object(
            CodexAppServerRecoveryProtocol.resumeThreadRequest(id: 2, threadID: threadID)
        )
        try require(resumeRequest["method"] as? String == "thread/resume")
        try require((resumeRequest["params"] as? [String: Any])?["threadId"] as? String == threadID)

        let readResponse = Data(#"{"id":3,"result":{"thread":{"id":"thread-gate0","turns":[{"id":"turn-existing","items":[{"type":"userMessage","id":"item-existing","clientId":"guardian:3d27c100-9a65-4c32-be13-703d89d0e829:9"}]}]}}}"#.utf8)
        try require(try CodexAppServerRecoveryProtocol.submission(
            inThreadReadResponse: readResponse,
            expectedRequestID: 3,
            expectedThreadID: threadID,
            clientMessageID: clientID
        ) == .alreadySubmitted(CodexAppServerRecoveryDelivery(
            threadID: threadID,
            turnID: "turn-existing",
            clientMessageID: clientID,
            userMessageItemID: "item-existing"
        )))

        let emptyReadResponse = Data(#"{"id":3,"result":{"thread":{"id":"thread-gate0","turns":[]}}}"#.utf8)
        try require(try CodexAppServerRecoveryProtocol.submission(
            inThreadReadResponse: emptyReadResponse,
            expectedRequestID: 3,
            expectedThreadID: threadID,
            clientMessageID: clientID
        ) == .missing)

        let resumeResponse = Data(#"{"id":2,"result":{"thread":{"id":"thread-gate0"}}}"#.utf8)
        try require(try CodexAppServerRecoveryProtocol.resumedThreadID(
            response: resumeResponse,
            expectedRequestID: 2
        ) == threadID)

        let startResponse = Data(#"{"id":4,"result":{"turn":{"id":"turn-new","status":"inProgress","items":[]}}}"#.utf8)
        try require(try CodexAppServerRecoveryProtocol.startedTurnID(
            response: startResponse,
            expectedRequestID: 4
        ) == "turn-new")

        let completion = Data(#"{"method":"turn/completed","params":{"threadId":"thread-gate0","turn":{"id":"turn-new","status":"completed","items":[]}}}"#.utf8)
        let finalReadResponse = Data(#"{"id":5,"result":{"thread":{"id":"thread-gate0","turns":[{"id":"turn-new","items":[{"type":"userMessage","id":"item-new","clientId":"guardian:3d27c100-9a65-4c32-be13-703d89d0e829:9"}]}]}}}"#.utf8)
        try require(try CodexAppServerRecoveryProtocol.completion(
            notification: completion,
            expectedThreadID: threadID,
            expectedTurnID: "turn-new"
        ) == .completed)
        try require(try CodexAppServerRecoveryProtocol.completion(
            notification: completion,
            expectedThreadID: "another-thread",
            expectedTurnID: "turn-new"
        ) == nil)

        let transport = SelfTestTransport(
            responses: [
                Data(#"{"id":1,"result":{"userAgent":"test"}}"#.utf8),
                resumeResponse,
                emptyReadResponse,
                startResponse,
                finalReadResponse,
            ],
            notifications: [completion]
        )
        let outcome = try CodexAppServerRecoveryCoordinator().recover(
            threadID: threadID,
            prompt: "Continue exact task",
            originToken: token,
            generation: 9,
            transport: transport,
            deadline: Date().addingTimeInterval(5)
        )
        try require(outcome == .completed(CodexAppServerRecoveryDelivery(
            threadID: threadID,
            turnID: "turn-new",
            clientMessageID: clientID,
            userMessageItemID: "item-new"
        )))
        try require(transport.methods == [
            "initialize",
            "thread/resume",
            "thread/read",
            "turn/start",
            "thread/read",
        ])

        guard CommandLine.arguments.count == 3 else { throw SelfTestError.failed }
        let collisionTransport = try CodexAppServerStdioTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [CommandLine.arguments[1]]
        )
        let collisionResponse = try collisionTransport.exchange(
            request: CodexAppServerRecoveryProtocol.initializeRequest(id: 1),
            deadline: Date().addingTimeInterval(5)
        )
        let collisionResponseObject = try object(collisionResponse)
        try require(collisionResponseObject["result"] != nil)
        try require(collisionResponseObject["method"] == nil)
        let collidingServerRequest = try collisionTransport.receive(
            deadline: Date().addingTimeInterval(5)
        )
        try require(try object(collidingServerRequest)["method"] as? String
            == "guardian/testRequest")
        collisionTransport.close()

        let stdioTransport = try CodexAppServerStdioTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [CommandLine.arguments[1]]
        )
        defer { stdioTransport.close() }
        let processOutcome = try CodexAppServerRecoveryCoordinator().recover(
            threadID: threadID,
            prompt: "Continue exact task",
            originToken: token,
            generation: 12,
            transport: stdioTransport,
            deadline: Date().addingTimeInterval(5)
        )
        try require(processOutcome == .completed(CodexAppServerRecoveryDelivery(
            threadID: threadID,
            turnID: "turn-fixture",
            clientMessageID: CodexAppServerRecoveryProtocol.clientMessageID(
                originToken: token,
                generation: 12
            ),
            userMessageItemID: "item-fixture"
        )))

        let installedTransport = try CodexAppServerStdioTransport(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[2])
        )
        defer { installedTransport.close() }
        let installedResponse = try installedTransport.exchange(
            request: CodexAppServerRecoveryProtocol.initializeRequest(id: 1),
            deadline: Date().addingTimeInterval(5)
        )
        try CodexAppServerRecoveryProtocol.validateResponse(
            installedResponse,
            expectedRequestID: 1
        )
        try installedTransport.send(
            notification: CodexAppServerRecoveryProtocol.initializedNotification(),
            deadline: Date().addingTimeInterval(5)
        )

        print("PASS: Gate 0 coordinator, process transport, and installed app-server handshake")
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SelfTestError.failed
        }
        return object
    }

    private static func require(_ condition: @autoclosure () throws -> Bool) throws {
        guard try condition() else { throw SelfTestError.failed }
    }
}

private enum SelfTestError: Error {
    case failed
}

private final class SelfTestTransport: @unchecked Sendable,
    CodexAppServerRecoveryTransport {
    private var responses: [Data]
    private var notifications: [Data]
    private(set) var methods: [String] = []

    init(responses: [Data], notifications: [Data]) {
        self.responses = responses
        self.notifications = notifications
    }

    func exchange(request: Data, deadline: Date) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: request) as? [String: Any]
        if let method = object?["method"] as? String { methods.append(method) }
        guard !responses.isEmpty else { throw SelfTestError.failed }
        return responses.removeFirst()
    }

    func send(notification: Data, deadline: Date) throws {}

    func receive(deadline: Date) throws -> Data {
        guard !notifications.isEmpty else { throw SelfTestError.failed }
        return notifications.removeFirst()
    }
}
