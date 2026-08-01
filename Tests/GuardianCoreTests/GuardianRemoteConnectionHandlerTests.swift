import Foundation
import GuardianCore
import Testing

@Test func privatePeerFrameRoutesOnceAndPreservesRequestIdentity() async throws {
    let probe = RemoteRouteProbe()
    let handler = GuardianRemoteConnectionHandler(
        rateLimitPolicy: connectionRatePolicy(maximumRequests: 4),
        route: { request, _, _ in try await probe.route(request) }
    )
    let request = GuardianRemoteWireRequest(
        protocolVersion: .current,
        requestID: UUID(),
        body: .ping(UUID())
    )

    let responseFrame = try await handler.handle(
        frame: GuardianRemoteWireCodec().encode(request),
        peerAddress: "192.168.1.25",
        currentGeneration: 3,
        now: Date(timeIntervalSince1970: 8_000)
    )
    let response = try GuardianRemoteWireCodec().decodeResponse(responseFrame)

    #expect(response.requestID == request.requestID)
    #expect(await probe.calls() == 1)
}

@Test func publicMalformedAndRateLimitedPeersNeverOverrunRouter() async throws {
    let probe = RemoteRouteProbe()
    let handler = GuardianRemoteConnectionHandler(
        rateLimitPolicy: connectionRatePolicy(maximumRequests: 1),
        route: { request, _, _ in try await probe.route(request) }
    )
    let request = GuardianRemoteWireRequest(
        protocolVersion: .current,
        requestID: UUID(),
        body: .ping(UUID())
    )
    let frame = try GuardianRemoteWireCodec().encode(request)
    let now = Date(timeIntervalSince1970: 8_000)

    await #expect(throws: GuardianRemoteConnectionError.peerRejected(.publicAddress)) {
        try await handler.handle(
            frame: frame,
            peerAddress: "8.8.8.8",
            currentGeneration: 3,
            now: now
        )
    }
    await #expect(throws: GuardianRemoteConnectionError.wire(.truncated)) {
        try await handler.handle(
            frame: Data([0, 0, 0]),
            peerAddress: "192.168.1.30",
            currentGeneration: 3,
            now: now
        )
    }
    _ = try await handler.handle(
        frame: frame,
        peerAddress: "192.168.1.31",
        currentGeneration: 3,
        now: now
    )
    await #expect(throws: GuardianRemoteConnectionError.rateLimited) {
        try await handler.handle(
            frame: frame,
            peerAddress: "192.168.1.31",
            currentGeneration: 3,
            now: now.addingTimeInterval(1)
        )
    }
    #expect(await probe.calls() == 1)
}

private actor RemoteRouteProbe {
    private var callCount = 0

    func route(_ request: GuardianRemoteWireRequest) throws -> GuardianRemoteWireResponse {
        callCount += 1
        return GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: request.requestID,
            body: .pong(UUID())
        )
    }

    func calls() -> Int { callCount }
}

private func connectionRatePolicy(maximumRequests: Int) -> GuardianRemoteRateLimitPolicy {
    GuardianRemoteRateLimitPolicy(
        maximumRequests: maximumRequests,
        requestWindow: 10,
        maximumAuthenticationFailures: 2,
        authenticationLockout: 30
    )
}
