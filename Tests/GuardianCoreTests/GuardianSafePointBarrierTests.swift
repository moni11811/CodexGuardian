import Foundation
import Testing
@testable import GuardianCore

@Test func taskStartingDuringFinalSerializedDrainBlocksRestart() async {
    let barrier = GuardianSafePointBarrier(maximumSnapshotAge: 10)
    let request = barrierRequest()
    await barrier.install(GuardianSafePointBarrierSnapshot(
        inventory: barrierInventory(tasks: [barrierIdle("requester")]),
        lastSequence: 10
    ))
    let counter = BarrierRestartCounter()

    let result = await barrier.attemptRestart(
        request: request,
        boundary: .serialized(generation: 7),
        now: Date(timeIntervalSince1970: 1_005),
        drainBufferedEvents: {
            [GuardianSafePointBarrierEvent(
                generation: 7,
                sequence: 11,
                observedAt: Date(timeIntervalSince1970: 1_004),
                mutation: .upsert(SafePointTaskObservation(
                    threadID: "other",
                    state: .active
                ))
            )]
        },
        issueRestart: { _ in counter.increment() }
    )

    #expect(result == .denied(.blocked(.activeTasks(["other"]))))
    #expect(counter.value == 0)
}

@Test func serializedIdleBoundaryIssuesExactlyOneRestart() async {
    let barrier = GuardianSafePointBarrier(maximumSnapshotAge: 10)
    let request = barrierRequest()
    await barrier.install(GuardianSafePointBarrierSnapshot(
        inventory: barrierInventory(tasks: [barrierIdle("requester")]),
        lastSequence: 10
    ))
    let counter = BarrierRestartCounter()

    let result = await barrier.attemptRestart(
        request: request,
        boundary: .serialized(generation: 7),
        now: Date(timeIntervalSince1970: 1_005),
        drainBufferedEvents: { [] },
        issueRestart: { _ in counter.increment() }
    )

    guard case let .issued(receipt) = result else {
        Issue.record("Expected a fenced restart receipt")
        return
    }
    #expect(receipt.operationID == request.operationID)
    #expect(receipt.generation == 7)
    #expect(receipt.throughSequence == 10)
    #expect(counter.value == 1)
}

@Test func unavailableAtomicBoundaryFailsClosed() async {
    let barrier = GuardianSafePointBarrier(maximumSnapshotAge: 10)
    await barrier.install(GuardianSafePointBarrierSnapshot(
        inventory: barrierInventory(tasks: [barrierIdle("requester")]),
        lastSequence: 10
    ))
    let counter = BarrierRestartCounter()

    let result = await barrier.attemptRestart(
        request: barrierRequest(),
        boundary: .unavailable,
        now: Date(timeIntervalSince1970: 1_005),
        drainBufferedEvents: { [] },
        issueRestart: { _ in counter.increment() }
    )

    #expect(result == .denied(.blocked(.unknown(.atomicBoundaryUnavailable))))
    #expect(counter.value == 0)
}

private func barrierRequest() -> SafePointRequest {
    SafePointRequest(
        operationID: UUID(uuidString: "59468DB0-D662-45D6-BBFC-BCE7BF7B1F49")!,
        originThreadID: "requester",
        originToken: UUID(uuidString: "9B850440-EFD9-4D03-A2C7-CDF89C27850B")!,
        expectedGeneration: 7
    )
}

private func barrierInventory(tasks: [SafePointTaskObservation]) -> SafePointInventory {
    SafePointInventory(
        tasks: tasks,
        capturedAt: Date(timeIntervalSince1970: 1_000),
        generation: 7,
        schemaIsSupported: true,
        isComplete: true,
        sequenceIsContiguous: true,
        hasConflictingEvidence: false
    )
}

private func barrierIdle(_ threadID: String) -> SafePointTaskObservation {
    SafePointTaskObservation(threadID: threadID, state: .idle)
}

private final class BarrierRestartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
