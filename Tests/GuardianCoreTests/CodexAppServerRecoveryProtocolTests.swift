import Foundation
import Testing
@testable import GuardianCore

@Test func recoveryProtocolBindsResumeReadAndTurnToOneExactThread() throws {
    let threadID = "019f0000-0000-7000-8000-000000000002"
    let originToken = try #require(UUID(uuidString: "3D27C100-9A65-4C32-BE13-703D89D0E829"))
    let clientMessageID = CodexAppServerRecoveryProtocol.clientMessageID(
        originToken: originToken,
        generation: 7
    )

    let initialize = try jsonObject(
        CodexAppServerRecoveryProtocol.initializeRequest(id: 1)
    )
    let resume = try jsonObject(
        CodexAppServerRecoveryProtocol.resumeThreadRequest(id: 2, threadID: threadID)
    )
    let read = try jsonObject(
        CodexAppServerRecoveryProtocol.readThreadRequest(id: 3, threadID: threadID)
    )
    let start = try jsonObject(
        CodexAppServerRecoveryProtocol.startRecoveryTurnRequest(
            id: 4,
            threadID: threadID,
            prompt: "Continue exact task",
            clientMessageID: clientMessageID
        )
    )

    #expect(initialize["method"] as? String == "initialize")
    #expect(resume["method"] as? String == "thread/resume")
    #expect((resume["params"] as? [String: Any])?["threadId"] as? String == threadID)
    #expect(read["method"] as? String == "thread/read")
    #expect((read["params"] as? [String: Any])?["threadId"] as? String == threadID)
    #expect((read["params"] as? [String: Any])?["includeTurns"] as? Bool == true)
    #expect(start["method"] as? String == "turn/start")
    #expect((start["params"] as? [String: Any])?["threadId"] as? String == threadID)
    #expect((start["params"] as? [String: Any])?["clientUserMessageId"] as? String
        == "guardian:3d27c100-9a65-4c32-be13-703d89d0e829:7")
}

@Test func recoveryProtocolSuppressesDuplicateLogicalContinuation() throws {
    let response = Data(#"{"id":3,"result":{"thread":{"id":"thread-1","turns":[{"id":"turn-existing","items":[{"type":"userMessage","id":"item-existing","clientId":"guardian:token:4","content":[]}] }]}}}"#.utf8)

    let submission = try CodexAppServerRecoveryProtocol.submission(
        inThreadReadResponse: response,
        expectedRequestID: 3,
        expectedThreadID: "thread-1",
        clientMessageID: "guardian:token:4"
    )

    #expect(submission == .alreadySubmitted(CodexAppServerRecoveryDelivery(
        threadID: "thread-1",
        turnID: "turn-existing",
        clientMessageID: "guardian:token:4",
        userMessageItemID: "item-existing"
    )))
}

@Test func recoveryProtocolRequiresExactThreadAndTurnCompletion() throws {
    let matching = Data(#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-9","status":"completed","items":[]}}}"#.utf8)
    let otherThread = Data(#"{"method":"turn/completed","params":{"threadId":"thread-2","turn":{"id":"turn-9","status":"completed","items":[]}}}"#.utf8)

    #expect(try CodexAppServerRecoveryProtocol.completion(
        notification: matching,
        expectedThreadID: "thread-1",
        expectedTurnID: "turn-9"
    ) == .completed)
    #expect(try CodexAppServerRecoveryProtocol.completion(
        notification: otherThread,
        expectedThreadID: "thread-1",
        expectedTurnID: "turn-9"
    ) == nil)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
