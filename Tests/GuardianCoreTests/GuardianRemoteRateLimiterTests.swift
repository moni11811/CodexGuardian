import Foundation
import GuardianCore
import Testing

@Test func remoteRateLimiterBoundsRequestsPerIdentityAndWindow() async {
    let limiter = GuardianRemoteRateLimiter(policy: .init(
        maximumRequests: 3,
        requestWindow: 10,
        maximumAuthenticationFailures: 2,
        authenticationLockout: 30
    ))
    let key = GuardianRemoteRateLimitKey.networkAddress("192.168.1.8")
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(await limiter.authorize(key, now: now) == .allowed(remaining: 2))
    #expect(await limiter.authorize(key, now: now.addingTimeInterval(1)) == .allowed(remaining: 1))
    #expect(await limiter.authorize(key, now: now.addingTimeInterval(2)) == .allowed(remaining: 0))
    #expect(await limiter.authorize(key, now: now.addingTimeInterval(3))
        == .rejected(retryAt: now.addingTimeInterval(10)))
    #expect(await limiter.authorize(key, now: now.addingTimeInterval(10))
        == .allowed(remaining: 2))
}

@Test func authenticationFailuresLockOnlyTheFailingRemoteIdentity() async {
    let limiter = GuardianRemoteRateLimiter(policy: .init(
        maximumRequests: 10,
        requestWindow: 10,
        maximumAuthenticationFailures: 2,
        authenticationLockout: 30
    ))
    let attacker = GuardianRemoteRateLimitKey.device(UUID())
    let healthy = GuardianRemoteRateLimitKey.device(UUID())
    let now = Date(timeIntervalSince1970: 10_000)

    await limiter.recordAuthenticationFailure(attacker, now: now)
    await limiter.recordAuthenticationFailure(attacker, now: now.addingTimeInterval(1))

    #expect(await limiter.authorize(attacker, now: now.addingTimeInterval(2))
        == .rejected(retryAt: now.addingTimeInterval(31)))
    #expect(await limiter.authorize(healthy, now: now.addingTimeInterval(2))
        == .allowed(remaining: 9))
    #expect(await limiter.authorize(attacker, now: now.addingTimeInterval(31))
        == .allowed(remaining: 9))
}
