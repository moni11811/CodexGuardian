import Foundation
import GuardianPhoneCore
import Testing
@testable import CodexGuardianPhone

struct GuardianPhoneProjectionMapperTests {
    @Test("remote task states map to one safe phone surface")
    func mapsTaskStatesAndCapabilities() {
        let now = Date(timeIntervalSince1970: 12_000)
        let remote = PhoneRemoteSnapshot(
            cursor: .init(generation: 7, sequence: 12),
            capturedAt: now,
            inventoryCompleteness: .complete,
            tasks: [
                task("attention", state: .stuck, now: now),
                task("active", state: .working, now: now),
                task("recent", state: .finished, now: now),
            ]
        )

        let snapshot = GuardianPhoneProjectionMapper().map(remote)

        #expect(snapshot.serverGeneration == 7)
        #expect(snapshot.tasks.map(\.id) == ["attention", "active", "recent"])
        #expect(snapshot.tasks.map(\.activity) == [.needsAttention, .active, .recent])
        #expect(snapshot.capabilities.first(where: { $0.action == .observe })?.isActionable == true)
        #expect(snapshot.capabilities.first(where: { $0.action == .promptAgent })?.isActionable == false)
        #expect(snapshot.capabilities.first(where: { $0.action == .restartAgent })?.isActionable == false)
    }

    @Test("authoritative recovery history maps newest-first with stable IDs")
    func mapsRecoveryHistory() {
        let now = Date(timeIntervalSince1970: 12_000)
        let olderID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        let newerID = UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
        let remote = PhoneRemoteSnapshot(
            cursor: .init(generation: 7, sequence: 12),
            capturedAt: now,
            inventoryCompleteness: .complete,
            tasks: [],
            operationHistory: [
                .init(
                    operationID: olderID,
                    kind: .nativeRecovery,
                    originThreadID: "thread-1",
                    phase: .acknowledged,
                    createdAt: now.addingTimeInterval(-20),
                    updatedAt: now.addingTimeInterval(-10)
                ),
                .init(
                    operationID: newerID,
                    kind: .hardRestart,
                    originThreadID: "thread-2",
                    phase: .waitingUser,
                    createdAt: now.addingTimeInterval(-5),
                    updatedAt: now
                ),
            ],
            operationHistoryCompleteness: .complete
        )

        let snapshot = GuardianPhoneProjectionMapper().map(remote)

        #expect(snapshot.operationHistory.map(\.id) == [newerID, olderID])
        #expect(snapshot.operationHistory.map(\.threadID) == ["thread-2", "thread-1"])
        #expect(snapshot.operationHistoryIsComplete)
    }

    @Test("authoritative command history preserves accepted versus applied")
    func mapsCommandHistoryWithoutUpgradingAccepted() throws {
        let now = Date(timeIntervalSince1970: 12_000)
        let commandID = UUID(uuidString: "71000000-0000-0000-0000-000000000003")!
        let deviceID = UUID(uuidString: "71000000-0000-0000-0000-000000000004")!
        let outcome = PhoneRemoteCommandOutcome(
            commandID: commandID,
            deviceID: deviceID,
            payloadDigest: Data(repeating: 0x31, count: 32),
            generation: 7,
            sequence: 1,
            acceptedAt: now.addingTimeInterval(-2),
            state: .accepted
        )
        let remote = PhoneRemoteSnapshot(
            cursor: .init(generation: 7, sequence: 12),
            capturedAt: now,
            inventoryCompleteness: .complete,
            tasks: [],
            commandHistory: .init(
                items: [
                    .init(
                        action: .prompt,
                        targetThreadID: "thread-1",
                        expectedGeneration: 7,
                        issuedAt: now.addingTimeInterval(-3),
                        deadline: now.addingTimeInterval(20),
                        outcome: outcome,
                        outcomeVersion: 1,
                        updatedAt: now.addingTimeInterval(-2)
                    ),
                ],
                totalCount: 1,
                completeness: .complete
            )
        )

        let snapshot = GuardianPhoneProjectionMapper().map(remote)
        let item = try #require(snapshot.commandHistory.first)

        #expect(item.id == commandID)
        #expect(item.action == .prompt)
        #expect(item.threadID == "thread-1")
        #expect(item.presentation == .acceptedByGuardian)
        #expect(snapshot.commandHistoryCompleteness == .complete)
        #expect(snapshot.commandHistoryTotalCount == 1)
    }

    private func task(
        _ id: String,
        state: PhoneRemoteTaskState,
        now: Date
    ) -> PhoneRemoteTaskSnapshot {
        .init(
            threadID: id,
            state: state,
            reason: "coherentEvidence",
            serverGeneration: 7,
            eventSequence: 12,
            confidence: 0.95,
            expiresAt: now.addingTimeInterval(10)
        )
    }
}
