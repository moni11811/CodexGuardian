import Foundation
import Testing
@testable import GuardianCore

@Test func taskStatesRouteToOneAttentionActiveRecentSurface() {
    let policy = GuardianOperatorPolicy(maximumSnapshotAge: 10)

    #expect(policy.section(for: .waitingUser) == .attention)
    #expect(policy.section(for: .stuck) == .attention)
    #expect(policy.section(for: .unknown) == .attention)
    #expect(policy.section(for: .slow) == .attention)
    #expect(policy.section(for: .working) == .active)
    #expect(policy.section(for: .recovering) == .active)
    #expect(policy.section(for: .idle) == .recent)
    #expect(policy.section(for: .finished) == .recent)
}

@Test func automaticRestartRequiresFreshCompleteIdleSupportedSnapshot() {
    let policy = GuardianOperatorPolicy(maximumSnapshotAge: 10)
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(policy.safeRestartAvailability(
        tasks: [operatorTask(.idle)],
        inventoryCompleteness: .complete,
        capturedAt: now.addingTimeInterval(-11),
        directControlSupported: true,
        now: now
    ) == .disabled(.staleSnapshot))
    #expect(policy.safeRestartAvailability(
        tasks: [operatorTask(.working)],
        inventoryCompleteness: .complete,
        capturedAt: now,
        directControlSupported: true,
        now: now
    ) == .disabled(.blockingTasks(["task-1"])))
    #expect(policy.safeRestartAvailability(
        tasks: [operatorTask(.idle)],
        inventoryCompleteness: .complete,
        capturedAt: now,
        directControlSupported: false,
        now: now
    ) == .disabled(.unsupportedControlPath))
}

@Test func forceRestartRequiresExplicitMacLocalConfirmation() {
    let policy = GuardianOperatorPolicy(maximumSnapshotAge: 10)

    #expect(policy.forceRestartAvailability(isMacLocal: false, isConfirmed: true)
        == .disabled(.macLocalOnly))
    #expect(policy.forceRestartAvailability(isMacLocal: true, isConfirmed: false)
        == .disabled(.confirmationRequired))
    #expect(policy.forceRestartAvailability(isMacLocal: true, isConfirmed: true) == .enabled)
}

@Test func operatorReadinessNamesExactBlockerInsteadOfGenericWaiting() {
    let operationID = UUID(uuidString: "74601F1F-97C1-47FC-B55B-40347BBC38A3")!
    let notice = GuardianOperatorPolicy(maximumSnapshotAge: 10).readinessNotice(
        operations: [GuardianIPCOperationSnapshot(
            operationID: operationID,
            originThreadID: "exact-thread",
            phase: "controlReady",
            readiness: .blocked(required: ["control.ready"])
        )]
    )

    #expect(notice == .blocked(
        operationID: operationID,
        capabilities: ["control.ready"]
    ))
}

private func operatorTask(_ state: AuthoritativeTaskState) -> GuardianIPCTaskSnapshot {
    GuardianIPCTaskSnapshot(
        threadID: "task-1",
        state: state,
        reason: .coherentEvidence,
        serverGeneration: 7,
        eventSequence: 10,
        confidence: 1,
        expiresAt: Date(timeIntervalSince1970: 1_100)
    )
}
