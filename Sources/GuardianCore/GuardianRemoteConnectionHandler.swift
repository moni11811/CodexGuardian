import Foundation

public enum GuardianRemoteConnectionError: Error, Equatable, Sendable {
    case peerRejected(GuardianRemotePeerRejection)
    case wire(GuardianRemoteWireError)
    case rateLimited
    case invalidGeneration
    case routingFailed
}

public actor GuardianRemoteConnectionHandler {
    public typealias Route = @Sendable (
        GuardianRemoteWireRequest,
        Int64,
        Date
    ) async throws -> GuardianRemoteWireResponse

    private let codec = GuardianRemoteWireCodec()
    private let limiter: GuardianRemoteRateLimiter
    private let route: Route

    public init(
        rateLimitPolicy: GuardianRemoteRateLimitPolicy,
        route: @escaping Route
    ) {
        limiter = GuardianRemoteRateLimiter(policy: rateLimitPolicy)
        self.route = route
    }

    public init(
        router: GuardianRemoteRequestRouter,
        rateLimitPolicy: GuardianRemoteRateLimitPolicy
    ) {
        limiter = GuardianRemoteRateLimiter(policy: rateLimitPolicy)
        route = { request, generation, now in
            try await router.handle(
                request,
                currentGeneration: generation,
                now: now
            )
        }
    }

    public func handle(
        frame: Data,
        peerAddress: String,
        currentGeneration: Int64,
        now: Date = Date()
    ) async throws -> Data {
        guard currentGeneration > 0,
              now.timeIntervalSince1970.isFinite else {
            throw GuardianRemoteConnectionError.invalidGeneration
        }
        switch GuardianRemotePeerAddressPolicy().evaluate(peerAddress) {
        case let .rejected(reason):
            throw GuardianRemoteConnectionError.peerRejected(reason)
        case .allowed:
            break
        }
        let addressKey = GuardianRemoteRateLimitKey.networkAddress(peerAddress)
        guard case .allowed = await limiter.authorize(addressKey, now: now) else {
            throw GuardianRemoteConnectionError.rateLimited
        }

        let request: GuardianRemoteWireRequest
        do {
            request = try codec.decodeRequest(frame)
        } catch let error as GuardianRemoteWireError {
            await limiter.recordAuthenticationFailure(addressKey, now: now)
            throw GuardianRemoteConnectionError.wire(error)
        } catch {
            await limiter.recordAuthenticationFailure(addressKey, now: now)
            throw GuardianRemoteConnectionError.wire(.invalidPayload)
        }

        let deviceKey: GuardianRemoteRateLimitKey?
        if case let .command(packet) = request.body {
            deviceKey = .device(packet.signedCommand.command.deviceID)
            guard case .allowed = await limiter.authorize(deviceKey!, now: now) else {
                throw GuardianRemoteConnectionError.rateLimited
            }
        } else if case let .pairing(pairing) = request.body {
            deviceKey = .device(pairing.claim.claim.deviceID)
            guard case .allowed = await limiter.authorize(deviceKey!, now: now) else {
                throw GuardianRemoteConnectionError.rateLimited
            }
        } else {
            deviceKey = nil
        }

        let response: GuardianRemoteWireResponse
        do {
            response = try await route(request, currentGeneration, now)
        } catch {
            throw GuardianRemoteConnectionError.routingFailed
        }
        guard response.protocolVersion == .current,
              response.requestID == request.requestID else {
            throw GuardianRemoteConnectionError.routingFailed
        }
        if Self.isAuthenticationFailure(response) {
            await limiter.recordAuthenticationFailure(addressKey, now: now)
            if let deviceKey {
                await limiter.recordAuthenticationFailure(deviceKey, now: now)
            }
        } else if Self.isAuthenticated(response) {
            await limiter.recordAuthenticationSuccess(addressKey)
            if let deviceKey {
                await limiter.recordAuthenticationSuccess(deviceKey)
            }
        }
        do {
            return try codec.encode(response)
        } catch let error as GuardianRemoteWireError {
            throw GuardianRemoteConnectionError.wire(error)
        } catch {
            throw GuardianRemoteConnectionError.wire(.invalidPayload)
        }
    }

    private static func isAuthenticationFailure(
        _ response: GuardianRemoteWireResponse
    ) -> Bool {
        if response.body == .rejected(.unauthorized) { return true }
        guard case let .gateway(.rejected(reason)) = response.body else { return false }
        switch reason {
        case .unknownDevice, .payloadDigestMismatch, .invalidPayload, .signature:
            return true
        case .payloadTooLarge, .payloadProtectionUnavailable, .adapterUnavailable:
            return false
        }
    }

    private static func isAuthenticated(_ response: GuardianRemoteWireResponse) -> Bool {
        switch response.body {
        case .paired, .observation, .eventBatch, .commandOutcome:
            true
        case .gateway(.rejected(.payloadProtectionUnavailable)),
             .gateway(.rejected(.adapterUnavailable)):
            true
        case let .gateway(.reconciled(result)):
            switch result {
            case .accepted, .duplicate, .snapshotRequired:
                true
            case .rejected:
                false
            }
        default:
            false
        }
    }
}
