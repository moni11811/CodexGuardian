import Foundation
import Testing
@testable import GuardianCore

@Test func successfulOpenWithoutRunningCodexIsNotRecovery() {
    let policy = CodexRelaunchPolicy()

    #expect(!policy.isRecovered(openSucceeded: true, applicationIsRunning: false))
    #expect(policy.isRecovered(openSucceeded: true, applicationIsRunning: true))
}

@Test func hardRecoveryRequiresANewCodexProcess() {
    let policy = CodexRelaunchPolicy()

    #expect(!policy.didRestart(previousProcessIDs: [41], currentProcessIDs: [41]))
    #expect(policy.didRestart(previousProcessIDs: [41], currentProcessIDs: [42]))
}

@Test func continuationWaitsForVerifiedDesktopRelaunch() {
    let policy = CodexRecoveryStartupPolicy()

    #expect(!policy.shouldStartContinuation(
        desktopIsRunning: false,
        appServerIsRunning: false,
        settledFor: 20
    ))
    #expect(!policy.shouldStartContinuation(
        desktopIsRunning: true,
        appServerIsRunning: false,
        settledFor: 20
    ))
    #expect(!policy.shouldStartContinuation(
        desktopIsRunning: true,
        appServerIsRunning: true,
        settledFor: 14
    ))
    #expect(policy.shouldStartContinuation(
        desktopIsRunning: true,
        appServerIsRunning: true,
        settledFor: 15
    ))
}

@Test func appServerGetsAFullSettleWindowAfterItAppears() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    var tracker = CodexRecoveryStartupTracker()

    let beforeServer = tracker.shouldStartContinuation(
        desktopIsRunning: true,
        appServerIsRunning: false,
        now: startedAt
    )
    let serverAppeared = tracker.shouldStartContinuation(
        desktopIsRunning: true,
        appServerIsRunning: true,
        now: startedAt.addingTimeInterval(14)
    )
    let oneSecondShort = tracker.shouldStartContinuation(
        desktopIsRunning: true,
        appServerIsRunning: true,
        now: startedAt.addingTimeInterval(28)
    )
    let fullySettled = tracker.shouldStartContinuation(
        desktopIsRunning: true,
        appServerIsRunning: true,
        now: startedAt.addingTimeInterval(29)
    )

    #expect(!beforeServer)
    #expect(!serverAppeared)
    #expect(!oneSecondShort)
    #expect(fullySettled)
}

@Test func recoveryDeepLinkTargetsExactDesktopThread() {
    let link = CodexThreadDeepLink(threadID: "019f0000-0000-7000-8000-000000000002")

    #expect(link.url.absoluteString == "codex://threads/019f0000-0000-7000-8000-000000000002")
}
