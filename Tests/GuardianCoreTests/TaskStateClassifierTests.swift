import Foundation
import Testing
@testable import GuardianCore

private let classifierNow = Date(timeIntervalSince1970: 10_000)

private func evidence(
    _ signal: TaskEvidenceSignal,
    source: TaskEvidenceSource = .appServerEvent,
    observedAt: Date = classifierNow.addingTimeInterval(-1),
    generation: Int64 = 7,
    sequence: Int64 = 11,
    confidence: Double = 1,
    expiresAt: Date = classifierNow.addingTimeInterval(30),
    inventory: TaskInventoryCompleteness = .notApplicable,
    verifiedHeartbeat: Bool = false
) -> TaskStateEvidence {
    TaskStateEvidence(
        taskID: "task-1",
        source: source,
        signal: signal,
        observedAt: observedAt,
        serverGeneration: generation,
        eventSequence: sequence,
        confidence: confidence,
        expiresAt: expiresAt,
        inventoryCompleteness: inventory,
        isVerifiedRecoveryHeartbeat: verifiedHeartbeat
    )
}

private func completeSnapshot(
    _ signal: TaskEvidenceSignal = .quiet,
    sequence: Int64 = 10
) -> TaskStateEvidence {
    evidence(
        signal,
        source: .appServerSnapshot,
        sequence: sequence,
        inventory: .complete
    )
}

@Test(arguments: [
    TaskEvidenceSignal.approvalRequired,
    .authenticationRequired,
    .permissionRequired,
])
func explicitUserWaitAlwaysClassifiesWaitingUser(_ signal: TaskEvidenceSignal) {
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [completeSnapshot(), evidence(signal)]
    )

    #expect(result.state == .waitingUser)
    #expect(!result.requiresFullSnapshot)
}

@Test(arguments: [TaskEvidenceSignal.progress, .ownedWork])
func quietTaskWithFreshProgressOrOwnedWorkIsRunning(_ signal: TaskEvidenceSignal) {
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [completeSnapshot(), evidence(signal)]
    )

    #expect(result.state == .working)
    #expect(result.state != .stuck)
}

@Test func expiredEvidenceFailsClosedToUnknown() {
    let expired = evidence(
        .stalled,
        source: .appServerSnapshot,
        expiresAt: classifierNow.addingTimeInterval(-1),
        inventory: .complete
    )

    let result = TaskStateClassifier().classify(now: classifierNow, evidence: [expired])

    #expect(result.state == .unknown)
    #expect(result.reason == .staleEvidence)
}

@Test func conflictingEvidenceAtOneSequenceFailsClosed() {
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [
            completeSnapshot(),
            evidence(.idle),
            evidence(.ownedWork),
        ]
    )

    #expect(result.state == .unknown)
    #expect(result.reason == .conflictingEvidence)
}

@Test func eventSequenceGapRequiresFullSnapshot() {
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [completeSnapshot(sequence: 40), evidence(.progress, sequence: 42)]
    )

    #expect(result.state == .unknown)
    #expect(result.reason == .sequenceGap)
    #expect(result.requiresFullSnapshot)
}

@Test func incompleteInventoryFailsClosed() {
    let snapshot = evidence(
        .idle,
        source: .appServerSnapshot,
        sequence: 20,
        inventory: .incomplete
    )

    let result = TaskStateClassifier().classify(now: classifierNow, evidence: [snapshot])

    #expect(result.state == .unknown)
    #expect(result.reason == .incompleteInventory)
    #expect(result.requiresFullSnapshot)
}

@Test func verifiedRecoveryHeartbeatAloneMayBeIgnored() {
    let heartbeat = evidence(
        .recoveryHeartbeat,
        source: .guardianRecoveryHeartbeat,
        sequence: 0,
        inventory: .notApplicable,
        verifiedHeartbeat: true
    )

    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [completeSnapshot(.idle), heartbeat]
    )

    #expect(result.state == .idle)
    #expect(result.ignoredVerifiedRecoveryHeartbeat)
}

@Test func resumedRequesterWorkBlocksDespiteRecoveryHeartbeat() {
    let heartbeat = evidence(
        .recoveryHeartbeat,
        source: .guardianRecoveryHeartbeat,
        sequence: 0,
        verifiedHeartbeat: true
    )
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [completeSnapshot(.idle), heartbeat, evidence(.requesterWork)]
    )

    #expect(result.state == .working)
    #expect(result.reason == .requesterWorkObserved)
}

@Test func coherentFreshStallCanBeClassifiedStuck() {
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [completeSnapshot(), evidence(.stalled)]
    )

    #expect(result.state == .stuck)
}

@Test func responsiveTaskPastSoftDeadlineIsSlowNotStuck() {
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [
            completeSnapshot(),
            evidence(.controlResponsive),
            evidence(.softDeadlineExceeded),
        ]
    )

    #expect(result.state == .slow)
    #expect(!result.requiresFullSnapshot)
}

@Test func terminalTaskIsFinished() {
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [completeSnapshot(), evidence(.terminal)]
    )

    #expect(result.state == .finished)
}

@Test func fencedRecoveryOwnerIsRecovering() {
    let result = TaskStateClassifier().classify(
        now: classifierNow,
        evidence: [completeSnapshot(), evidence(.recoveryOwned)]
    )

    #expect(result.state == .recovering)
}
