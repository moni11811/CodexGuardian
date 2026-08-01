import Foundation
import Testing
@testable import GuardianCore

@Test func stdioTransportKeepsCollidingServerRequestSeparateFromResponse() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/FakeCodexAppServer.py")
    let transport = try CodexAppServerStdioTransport(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [fixture.path]
    )
    defer { transport.close() }

    let response = try transport.exchange(
        request: CodexAppServerRecoveryProtocol.initializeRequest(id: 1),
        deadline: Date().addingTimeInterval(5)
    )
    let responseObject = try #require(
        JSONSerialization.jsonObject(with: response) as? [String: Any]
    )
    #expect(responseObject["result"] != nil)
    #expect(responseObject["method"] == nil)

    let serverRequest = try transport.receive(deadline: Date().addingTimeInterval(5))
    let requestObject = try #require(
        JSONSerialization.jsonObject(with: serverRequest) as? [String: Any]
    )
    #expect(requestObject["method"] as? String == "guardian/testRequest")
}

@Test func stdioTransportRunsExactThreePhaseLoopAgainstProcessFixture() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/FakeCodexAppServer.py")
    let transport = try CodexAppServerStdioTransport(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [fixture.path]
    )
    defer { transport.close() }
    let token = try #require(UUID(uuidString: "3D27C100-9A65-4C32-BE13-703D89D0E829"))

    let outcome = try CodexAppServerRecoveryCoordinator().recover(
        threadID: "thread-gate0",
        prompt: "Continue exact task",
        originToken: token,
        generation: 11,
        transport: transport,
        deadline: Date().addingTimeInterval(5)
    )

    #expect(outcome == .completed(CodexAppServerRecoveryDelivery(
        threadID: "thread-gate0",
        turnID: "turn-fixture",
        clientMessageID: CodexAppServerRecoveryProtocol.clientMessageID(
            originToken: token,
            generation: 11
        ),
        userMessageItemID: "item-fixture"
    )))
}
