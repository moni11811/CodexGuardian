import Foundation
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone safety state")
struct GuardianPhoneCoreSafetyTests {
    @Test("pending command never represents applied")
    func pendingCommandNeverRepresentsApplied() {
        let command = PhoneCommandRecord(
            id: OperationID("op-1"),
            action: .restartAgent,
            state: .pending,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        #expect(command.isApplied == false)
        #expect(command.presentation == .waitingForGuardian)
    }

    @Test("destructive actions require a fresh complete known impact snapshot")
    func destructiveActionRequiresFreshCompleteImpactSnapshot() {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = DestructiveActionPolicy(maximumSnapshotAge: 30)
        let fresh = ImpactSnapshot(
            targetThreadID: "thread-a",
            serverGeneration: 7,
            capturedAt: now.addingTimeInterval(-10),
            completeness: .complete,
            impact: .known(activeTaskCount: 0, uncommittedWorkspaceCount: 0)
        )

        #expect(policy.authorization(
            for: .restartAgent,
            targetThreadID: "thread-a",
            expectedGeneration: 7,
            snapshot: fresh,
            now: now
        ) == .allowed)

        let stale = ImpactSnapshot(
            targetThreadID: "thread-a",
            serverGeneration: 7,
            capturedAt: now.addingTimeInterval(-31),
            completeness: .complete,
            impact: .known(activeTaskCount: 0, uncommittedWorkspaceCount: 0)
        )
        #expect(policy.authorization(
            for: .restartAgent,
            targetThreadID: "thread-a",
            expectedGeneration: 7,
            snapshot: stale,
            now: now
        ) == .denied(.staleSnapshot))

        let partial = ImpactSnapshot(
            targetThreadID: "thread-a",
            serverGeneration: 7,
            capturedAt: now,
            completeness: .partial,
            impact: .known(activeTaskCount: 0, uncommittedWorkspaceCount: 0)
        )
        #expect(policy.authorization(
            for: .restartAgent,
            targetThreadID: "thread-a",
            expectedGeneration: 7,
            snapshot: partial,
            now: now
        ) == .denied(.incompleteSnapshot))

        let unknown = ImpactSnapshot(
            targetThreadID: "thread-a",
            serverGeneration: 7,
            capturedAt: now,
            completeness: .complete,
            impact: .unknown
        )
        #expect(policy.authorization(
            for: .restartAgent,
            targetThreadID: "thread-a",
            expectedGeneration: 7,
            snapshot: unknown,
            now: now
        ) == .denied(.unknownImpact))
    }

    @Test("restart impact is bound to the exact task and server generation")
    func restartImpactRejectsAnotherTaskOrGeneration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = DestructiveActionPolicy(maximumSnapshotAge: 30)
        let snapshot = ImpactSnapshot(
            targetThreadID: "thread-a",
            serverGeneration: 7,
            capturedAt: now,
            completeness: .complete,
            impact: .known(activeTaskCount: 0, uncommittedWorkspaceCount: 0)
        )

        #expect(policy.authorization(
            for: .restartAgent,
            targetThreadID: "thread-b",
            expectedGeneration: 7,
            snapshot: snapshot,
            now: now
        ) == .denied(.targetMismatch))
        #expect(policy.authorization(
            for: .restartAgent,
            targetThreadID: "thread-a",
            expectedGeneration: 8,
            snapshot: snapshot,
            now: now
        ) == .denied(.generationMismatch))
    }

    @Test("opaque notification carries only operation ID and rejects sensitive content")
    func opaqueNotificationRejectsSensitiveContent() throws {
        let valid = try OpaqueNotificationPayload(userInfo: ["operation_id": "op-1"])
        #expect(valid.operationID == OperationID("op-1"))
        #expect(valid.userInfo == ["operation_id": "op-1"])

        #expect(throws: OpaqueNotificationError.self) {
            try OpaqueNotificationPayload(userInfo: [
                "operation_id": "op-1",
                "prompt": "Restart private project",
            ])
        }
        #expect(throws: OpaqueNotificationError.self) {
            try OpaqueNotificationPayload(userInfo: ["operation_id": "op-1", "aps": "result text"])
        }
    }

    @Test("generation or sequence gap requires a full snapshot")
    func continuityGapRequiresFullSnapshot() {
        let cursor = ProjectionCursor(generation: 7, sequence: 41)

        #expect(cursor.recovery(for: ProjectionEnvelope(generation: 7, sequence: 42)) == .acceptIncrement)
        #expect(cursor.recovery(for: ProjectionEnvelope(generation: 7, sequence: 44)) == .requireFullSnapshot)
        #expect(cursor.recovery(for: ProjectionEnvelope(generation: 8, sequence: 1)) == .requireFullSnapshot)
    }

    @Test("adapter unavailable capability is not actionable")
    func adapterUnavailableCapabilityIsNotActionable() {
        let capability = PhoneCapability(action: .promptAgent, availability: .adapterUnavailable)
        #expect(capability.isActionable == false)
    }

    @Test("mutating commands require an exact task and positive generation")
    func mutationTargetRequiresTaskAndGeneration() {
        #expect(PhoneCommandTarget(threadID: "thread-a", serverGeneration: 7).isValid)
        #expect(!PhoneCommandTarget(threadID: "", serverGeneration: 7).isValid)
        #expect(!PhoneCommandTarget(threadID: "thread-a", serverGeneration: 0).isValid)
    }

    @Test("offline duplicate command ID preserves one local record")
    func offlineDuplicateCommandPreservesOneRecord() {
        let command = PhoneCommandRecord(
            id: OperationID("op-duplicate"),
            action: .promptAgent,
            state: .pending,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        var queue = OfflineCommandQueue()

        #expect(queue.enqueue(command) == .inserted)
        #expect(queue.enqueue(command) == .duplicateIgnored)
        #expect(queue.records == [command])
    }
}
