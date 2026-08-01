import Foundation
import Testing
@testable import GuardianCore

@Suite(.serialized)
struct GuardianTaskProjectionEngineTests {
    @Test func globalEventsPreserveUnchangedTasksWithoutFalseSequenceGap() async throws {
        let fixture = try Fixture()
        let initial = try await fixture.engine.applySnapshot(
            fixture.snapshot(items: [
                .init(taskID: "task-a", signal: .progress, confidence: 1),
                .init(taskID: "task-b", signal: .idle, confidence: 1),
            ]),
            now: fixture.now
        )
        #expect(initial.inventory?.tasks["task-a"]?.state == .working)
        #expect(initial.inventory?.tasks["task-b"]?.state == .idle)

        let approval = try await fixture.engine.applyEvent(
            fixture.event(taskID: "task-b", signal: .approvalRequired, sequence: 11),
            now: fixture.now
        )
        #expect(approval.inventory?.tasks["task-a"]?.state == .working)
        #expect(approval.inventory?.tasks["task-b"]?.state == .waitingUser)

        let terminal = try await fixture.engine.applyEvent(
            fixture.event(taskID: "task-a", signal: .terminal, sequence: 12),
            now: fixture.now
        )
        #expect(terminal.inventory?.eventSequence == 12)
        #expect(terminal.inventory?.tasks["task-a"]?.state == .finished)
        #expect(terminal.inventory?.tasks["task-b"]?.state == .waitingUser)

        let stored = try fixture.journal.taskSnapshots()
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.eventSequence == 12 })
    }

    @Test func globalSequenceGapRequiresSnapshotWithoutAdvancingCursor() async throws {
        let fixture = try Fixture()
        _ = try await fixture.engine.applySnapshot(
            fixture.snapshot(items: [.init(taskID: "task-a", signal: .idle, confidence: 1)]),
            now: fixture.now
        )

        let result = try await fixture.engine.applyEvent(
            fixture.event(taskID: "task-a", signal: .progress, sequence: 12),
            now: fixture.now
        )

        #expect(result == .resnapshotRequired(.sequenceGap(expected: 11, observed: 12)))
        let current = await fixture.engine.currentInventory()
        #expect(current?.eventSequence == 10)
        #expect(try fixture.journal.taskSnapshots().first?.eventSequence == 10)
    }

    @Test func generationChangeUnknownTaskAndIncompleteInventoryFailClosed() async throws {
        let fixture = try Fixture()
        _ = try await fixture.engine.applySnapshot(
            fixture.snapshot(items: [.init(taskID: "task-a", signal: .idle, confidence: 1)]),
            now: fixture.now
        )

        let generation = try await fixture.engine.applyEvent(
            fixture.event(taskID: "task-a", signal: .progress, sequence: 11, generation: 8),
            now: fixture.now
        )
        #expect(generation == .resnapshotRequired(.generationChanged(expected: 7, observed: 8)))

        let unknown = try await fixture.engine.applyEvent(
            fixture.event(taskID: "task-new", signal: .progress, sequence: 11),
            now: fixture.now
        )
        #expect(unknown == .resnapshotRequired(.unknownTask("task-new")))

        let incomplete = try await fixture.engine.applySnapshot(
            fixture.snapshot(
                completeness: .incomplete,
                items: [.init(taskID: "task-a", signal: .idle, confidence: 1)]
            ),
            now: fixture.now
        )
        #expect(incomplete == .resnapshotRequired(.incompleteInventory))
    }

    @Test func newerCompleteSnapshotAtomicallyRemovesDisappearedTasks() async throws {
        let fixture = try Fixture()
        _ = try await fixture.engine.applySnapshot(
            fixture.snapshot(items: [
                .init(taskID: "task-a", signal: .idle, confidence: 1),
                .init(taskID: "task-b", signal: .idle, confidence: 1),
            ]),
            now: fixture.now
        )
        let replacement = GuardianTaskInventorySnapshot(
            serverGeneration: 7,
            eventSequence: 20,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(30),
            completeness: .complete,
            items: [.init(taskID: "task-a", signal: .progress, confidence: 1)]
        )

        _ = try await fixture.engine.applySnapshot(replacement, now: fixture.now)

        let stored = try fixture.journal.taskSnapshots()
        #expect(stored.map(\.threadID) == ["task-a"])
        #expect(stored.first?.eventSequence == 20)
    }

    @Test func provenEmptyInventoryIsDurableAndDistinctFromMissingObserver() async throws {
        let fixture = try Fixture()

        let result = try await fixture.engine.applySnapshot(
            fixture.snapshot(items: []),
            now: fixture.now
        )

        #expect(result.inventory?.tasks.isEmpty == true)
        #expect(try fixture.journal.taskSnapshots().isEmpty)
        #expect(try fixture.journal.taskProjectionCheckpoint() == GuardianTaskProjectionCheckpoint(
            serverGeneration: 7,
            eventSequence: 10,
            capturedAt: fixture.now.addingTimeInterval(-1),
            expiresAt: fixture.now.addingTimeInterval(30),
            inventoryCompleteness: .complete
        ))
    }

    private struct Fixture {
        let now = Date(timeIntervalSince1970: 90_000)
        let journal: GuardianJournal
        let engine: GuardianTaskProjectionEngine

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "guardian-projector-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
            engine = GuardianTaskProjectionEngine(journal: journal)
        }

        func snapshot(
            completeness: TaskInventoryCompleteness = .complete,
            items: [GuardianTaskInventoryItem]
        ) -> GuardianTaskInventorySnapshot {
            GuardianTaskInventorySnapshot(
                serverGeneration: 7,
                eventSequence: 10,
                observedAt: now.addingTimeInterval(-1),
                expiresAt: now.addingTimeInterval(30),
                completeness: completeness,
                items: items
            )
        }

        func event(
            taskID: String,
            signal: TaskEvidenceSignal,
            sequence: Int64,
            generation: Int64 = 7
        ) -> GuardianTaskLifecycleEvent {
            GuardianTaskLifecycleEvent(
                taskID: taskID,
                signal: signal,
                serverGeneration: generation,
                eventSequence: sequence,
                observedAt: now,
                expiresAt: now.addingTimeInterval(30),
                confidence: 1
            )
        }
    }
}
