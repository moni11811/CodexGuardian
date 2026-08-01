import Foundation
import Testing
@testable import GuardianCore

private let operationID = UUID(uuidString: "31A25291-BDB6-44EF-AAB8-A95450F99A91")!
private let originToken = UUID(uuidString: "FF9F8881-7FC3-4427-B8ED-95E1F4BBBB2A")!
private let capturedAt = Date(timeIntervalSince1970: 1_000)

private func request(forceBypassRequested: Bool = false) -> SafePointRequest {
    SafePointRequest(
        operationID: operationID,
        originThreadID: "requester",
        originToken: originToken,
        expectedGeneration: 7,
        forceBypassRequested: forceBypassRequested
    )
}

private func inventory(
    tasks: [SafePointTaskObservation],
    capturedAt: Date = capturedAt,
    generation: Int64 = 7,
    schemaIsSupported: Bool = true,
    isComplete: Bool = true,
    sequenceIsContiguous: Bool = true,
    hasConflictingEvidence: Bool = false
) -> SafePointInventory {
    SafePointInventory(
        tasks: tasks,
        capturedAt: capturedAt,
        generation: generation,
        schemaIsSupported: schemaIsSupported,
        isComplete: isComplete,
        sequenceIsContiguous: sequenceIsContiguous,
        hasConflictingEvidence: hasConflictingEvidence
    )
}

private func idle(_ threadID: String) -> SafePointTaskObservation {
    SafePointTaskObservation(threadID: threadID, state: .idle)
}

private func active(
    _ threadID: String,
    role: SafePointActivityRole = .ordinary
) -> SafePointTaskObservation {
    SafePointTaskObservation(threadID: threadID, state: .active, role: role)
}

private func decision(
    _ inventory: SafePointInventory,
    request: SafePointRequest = request(),
    now: Date = capturedAt.addingTimeInterval(5)
) -> SafePointDecision {
    SafePointPolicy(maximumSnapshotAge: 10).decision(
        request: request,
        inventory: inventory,
        now: now
    )
}

@Test func unrelatedActiveTaskBlocksGlobalSafePoint() {
    let result = decision(inventory(tasks: [idle("requester"), active("other")]))

    #expect(result == .blocked(.activeTasks(["other"])))
}

@Test func realResumedWorkInRequesterBlocksGlobalSafePoint() {
    let result = decision(inventory(tasks: [active("requester")]))

    #expect(result == .blocked(.activeTasks(["requester"])))
}

@Test func onlyVerifiedHeartbeatForExactOriginOperationMayBeIgnored() {
    let exactHeartbeat = SafePointHeartbeatProof(
        operationID: operationID,
        originThreadID: "requester",
        originToken: originToken,
        isVerified: true
    )
    let allowed = decision(inventory(tasks: [
        active("requester", role: .recoveryHeartbeat(exactHeartbeat)),
        idle("other"),
    ]))

    let wrongOperation = SafePointHeartbeatProof(
        operationID: UUID(uuidString: "29DC80A4-B95C-4802-8E7D-4759448D2FD4")!,
        originThreadID: "requester",
        originToken: originToken,
        isVerified: true
    )
    let blocked = decision(inventory(tasks: [
        active("requester", role: .recoveryHeartbeat(wrongOperation)),
    ]))

    #expect(allowed == .automaticRestartAllowed)
    #expect(blocked == .blocked(.activeTasks(["requester"])))
}

@Test func unverifiedHeartbeatCannotBeIgnored() {
    let heartbeat = SafePointHeartbeatProof(
        operationID: operationID,
        originThreadID: "requester",
        originToken: originToken,
        isVerified: false
    )

    let result = decision(inventory(tasks: [
        active("requester", role: .recoveryHeartbeat(heartbeat)),
    ]))

    #expect(result == .blocked(.activeTasks(["requester"])))
}

@Test func staleSnapshotBlocksAsUnknown() {
    let result = decision(
        inventory(tasks: [idle("requester")]),
        now: capturedAt.addingTimeInterval(11)
    )

    #expect(result == .blocked(.unknown(.staleSnapshot)))
}

@Test func sequenceGapBlocksAsUnknown() {
    let result = decision(inventory(
        tasks: [idle("requester")],
        sequenceIsContiguous: false
    ))

    #expect(result == .blocked(.unknown(.sequenceGap)))
}

@Test func incompleteInventoryBlocksAsUnknown() {
    let result = decision(inventory(tasks: [idle("requester")], isComplete: false))

    #expect(result == .blocked(.unknown(.incompleteInventory)))
}

@Test func unsupportedSchemaBlocksAsUnknown() {
    let result = decision(inventory(
        tasks: [idle("requester")],
        schemaIsSupported: false
    ))

    #expect(result == .blocked(.unknown(.unsupportedSchema)))
}

@Test func conflictingEvidenceBlocksAsUnknown() {
    let result = decision(inventory(
        tasks: [idle("requester")],
        hasConflictingEvidence: true
    ))

    #expect(result == .blocked(.unknown(.conflictingEvidence)))
}

@Test func generationChangeSinceDecisionRequiresResnapshot() {
    let result = decision(inventory(tasks: [idle("requester")], generation: 8))

    #expect(result == .resnapshotRequired(expectedGeneration: 7, observedGeneration: 8))
}

@Test func completeFreshIdleInventoryPermitsAutomaticRestart() {
    let result = decision(inventory(tasks: [idle("requester"), idle("other")]))

    #expect(result == .automaticRestartAllowed)
}

@Test func forceBypassIsNeverAnAutomaticPolicyDecision() {
    let result = decision(
        inventory(tasks: [active("other")]),
        request: request(forceBypassRequested: true)
    )

    #expect(result == .blocked(.humanForceRequired))
}
