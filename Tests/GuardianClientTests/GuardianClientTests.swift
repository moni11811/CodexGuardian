import Foundation
import Darwin
import GuardianClient
import GuardianCore
import Testing

private actor FakeGuardianTransport: GuardianClientTransport {
    private(set) var receivedRequest: GuardianDaemonRequest?

    func exchange(frame: Data, deadline: Date) async throws -> Data {
        var decoder = GuardianIPCFrameDecoder()
        let requestFrame = try #require(decoder.append(frame).first)
        receivedRequest = try JSONDecoder().decode(GuardianDaemonRequest.self, from: requestFrame)
        let reply = GuardianDaemonReply.rejected(.shadowMode)
        return try GuardianIPCFrameCodec.encode(JSONEncoder().encode(reply))
    }
}

private actor SnapshotGuardianTransport: GuardianClientTransport {
    private(set) var receivedRequest: GuardianDaemonRequest?
    let snapshot: GuardianIPCFullSnapshot

    init(snapshot: GuardianIPCFullSnapshot) {
        self.snapshot = snapshot
    }

    func exchange(frame: Data, deadline: Date) async throws -> Data {
        var decoder = GuardianIPCFrameDecoder()
        let requestFrame = try #require(decoder.append(frame).first)
        receivedRequest = try JSONDecoder().decode(GuardianDaemonRequest.self, from: requestFrame)
        return try GuardianIPCFrameCodec.encode(
            JSONEncoder().encode(GuardianDaemonReply.snapshot(snapshot))
        )
    }
}

@Test func guardianClientFramesAuthenticatedRequestAndDecodesReply() async throws {
    let transport = FakeGuardianTransport()
    let credential = Data(repeating: 0xA5, count: 32)
    let clientID = UUID()
    let client = GuardianClient(
        clientID: clientID,
        credential: credential,
        transport: transport
    )
    let command = GuardianIPCCommand(
        protocolVersion: .current,
        rpcID: UUID(),
        operationID: UUID(),
        clientID: clientID,
        expectedGeneration: 1,
        deadline: Date().addingTimeInterval(10),
        originThreadID: "thread-1",
        targetThreadID: "thread-1",
        action: .recover,
        force: false
    )

    #expect(try await client.send(command) == .rejected(.shadowMode))
    let received = await transport.receivedRequest
    #expect(received == GuardianDaemonRequest(credential: credential, command: command))
}

@Test func guardianClientBuildsReadOnlyInitialObservation() async throws {
    let clientID = UUID()
    let snapshot = GuardianIPCFullSnapshot(
        protocolVersion: .current,
        generation: 3,
        lastSequence: 9,
        capturedAt: Date(timeIntervalSince1970: 100),
        operations: []
    )
    let transport = SnapshotGuardianTransport(snapshot: snapshot)
    let client = GuardianClient(
        clientID: clientID,
        credential: Data(repeating: 0xA5, count: 32),
        transport: transport
    )

    #expect(try await client.observeSnapshot(
        originThreadID: "mac-ui",
        deadline: Date(timeIntervalSinceNow: 10)
    ) == snapshot)
    let request = await transport.receivedRequest
    #expect(request?.command.action == .observe)
    #expect(request?.command.expectedGeneration == 0)
    #expect(request?.command.originThreadID == "mac-ui")
    #expect(request?.command.targetThreadID == "mac-ui")
}

@Test func connectedUnixPeerMustMatchExpectedExecutableBeforeCredentialsSend() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    defer {
        Darwin.close(descriptors[0])
        Darwin.close(descriptors[1])
    }

    let identity = try GuardianUnixPeerIdentity.inspect(descriptor: descriptors[0])
    #expect(identity.processID == getpid())
    #expect(!identity.executablePath.isEmpty)
    try GuardianUnixPeerIdentity.verify(
        descriptor: descriptors[0],
        expectedExecutablePath: identity.executablePath
    )
    #expect(throws: GuardianUnixSocketError.untrustedPeer) {
        try GuardianUnixPeerIdentity.verify(
            descriptor: descriptors[0],
            expectedExecutablePath: "/tmp/not-guardian-daemon"
        )
    }
}
