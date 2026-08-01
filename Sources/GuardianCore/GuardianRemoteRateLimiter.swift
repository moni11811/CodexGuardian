import Foundation

public enum GuardianRemoteRateLimitKey: Hashable, Sendable {
    case networkAddress(String)
    case device(UUID)
}

public struct GuardianRemoteRateLimitPolicy: Codable, Equatable, Sendable {
    public let maximumRequests: Int
    public let requestWindow: TimeInterval
    public let maximumAuthenticationFailures: Int
    public let authenticationLockout: TimeInterval

    public init(
        maximumRequests: Int,
        requestWindow: TimeInterval,
        maximumAuthenticationFailures: Int,
        authenticationLockout: TimeInterval
    ) {
        self.maximumRequests = maximumRequests
        self.requestWindow = requestWindow
        self.maximumAuthenticationFailures = maximumAuthenticationFailures
        self.authenticationLockout = authenticationLockout
    }

    public static let productionDefault = GuardianRemoteRateLimitPolicy(
        maximumRequests: 120,
        requestWindow: 60,
        maximumAuthenticationFailures: 5,
        authenticationLockout: 300
    )

    public var isValid: Bool {
        maximumRequests > 0
            && requestWindow > 0
            && requestWindow.isFinite
            && maximumAuthenticationFailures > 0
            && authenticationLockout > 0
            && authenticationLockout.isFinite
    }
}

public enum GuardianRemoteRateLimitDecision: Equatable, Sendable {
    case allowed(remaining: Int)
    case rejected(retryAt: Date)
}

public actor GuardianRemoteRateLimiter {
    private struct State {
        var windowStartedAt: Date
        var requestCount: Int
        var authenticationFailures: Int
        var lockoutUntil: Date?
    }

    private let policy: GuardianRemoteRateLimitPolicy
    private var states: [GuardianRemoteRateLimitKey: State] = [:]

    public init(policy: GuardianRemoteRateLimitPolicy) {
        precondition(policy.isValid, "Remote rate-limit policy must be positive and finite")
        self.policy = policy
    }

    public func authorize(
        _ key: GuardianRemoteRateLimitKey,
        now: Date = Date()
    ) -> GuardianRemoteRateLimitDecision {
        var state = normalizedState(for: key, now: now)
        if let lockoutUntil = state.lockoutUntil, lockoutUntil > now {
            states[key] = state
            return .rejected(retryAt: lockoutUntil)
        }
        let retryAt = state.windowStartedAt.addingTimeInterval(policy.requestWindow)
        guard state.requestCount < policy.maximumRequests else {
            states[key] = state
            return .rejected(retryAt: retryAt)
        }
        state.requestCount += 1
        states[key] = state
        return .allowed(remaining: policy.maximumRequests - state.requestCount)
    }

    public func recordAuthenticationFailure(
        _ key: GuardianRemoteRateLimitKey,
        now: Date = Date()
    ) {
        var state = normalizedState(for: key, now: now)
        guard state.lockoutUntil.map({ $0 > now }) != true else {
            states[key] = state
            return
        }
        state.authenticationFailures += 1
        if state.authenticationFailures >= policy.maximumAuthenticationFailures {
            state.lockoutUntil = now.addingTimeInterval(policy.authenticationLockout)
        }
        states[key] = state
    }

    public func recordAuthenticationSuccess(_ key: GuardianRemoteRateLimitKey) {
        guard var state = states[key] else { return }
        state.authenticationFailures = 0
        state.lockoutUntil = nil
        states[key] = state
    }

    private func normalizedState(
        for key: GuardianRemoteRateLimitKey,
        now: Date
    ) -> State {
        var state = states[key] ?? State(
            windowStartedAt: now,
            requestCount: 0,
            authenticationFailures: 0,
            lockoutUntil: nil
        )
        if now >= state.windowStartedAt.addingTimeInterval(policy.requestWindow) {
            state.windowStartedAt = now
            state.requestCount = 0
        }
        if let lockoutUntil = state.lockoutUntil, now >= lockoutUntil {
            state.authenticationFailures = 0
            state.lockoutUntil = nil
        }
        return state
    }
}
