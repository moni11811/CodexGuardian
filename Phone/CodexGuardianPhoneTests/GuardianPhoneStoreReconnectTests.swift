import Foundation
import GuardianPhoneCore
import Testing
@testable import CodexGuardianPhone

@Suite("Guardian phone reconnect lifecycle")
struct GuardianPhoneStoreReconnectTests {
    @Test("transient loss reconnects without a manual retry")
    @MainActor
    func transientLossReconnectsAutomatically() async throws {
        let snapshot = GuardianPhoneSnapshot(
            tasks: [],
            capabilities: [PhoneCapability(action: .observe, availability: .available)],
            computerName: "Paired Mac",
            serverGeneration: 9
        )
        let service = ReconnectSequenceService(snapshot: snapshot)
        let sleeper = ReconnectSleepRecorder()
        let store = GuardianPhoneStore(
            service: service,
            reconnectSleep: { delay in await sleeper.sleep(delay) }
        )

        await store.monitor(maximumAttempts: 2)

        #expect(store.connection == .ready)
        #expect(store.serverGeneration == 9)
        #expect(await service.loadCount == 2)
        #expect(await sleeper.delays == [1])
    }

    @Test("deterministic storage failure opens the circuit without retry")
    @MainActor
    func deterministicFailureStops() async {
        let service = PermanentFailureService()
        let sleeper = ReconnectSleepRecorder()
        let store = GuardianPhoneStore(
            service: service,
            reconnectSleep: { delay in await sleeper.sleep(delay) }
        )

        await store.monitor(maximumAttempts: 3)

        #expect(await service.loadCount == 1)
        #expect(await sleeper.delays.isEmpty)
        guard case .failed = store.connection else {
            Issue.record("Expected a closed reconnect circuit")
            return
        }
    }
}

private actor ReconnectSequenceService: GuardianPhoneService {
    private let snapshot: GuardianPhoneSnapshot
    private(set) var loadCount = 0

    init(snapshot: GuardianPhoneSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> GuardianPhoneSnapshot {
        loadCount += 1
        if loadCount == 1 { throw URLError(.networkConnectionLost) }
        return snapshot
    }

    func pair(code _: String) async throws {}
    func sendPrompt(_: String, to _: PhoneCommandTarget) async throws {}
    func fetchRestartImpact(for _: PhoneCommandTarget) async throws -> ImpactSnapshot {
        throw GuardianPhoneServiceError.transportUnavailable
    }
    func restartAgent(using _: ImpactSnapshot) async throws {}
}

private actor ReconnectSleepRecorder {
    private(set) var delays: [TimeInterval] = []

    func sleep(_ delay: TimeInterval) {
        delays.append(delay)
    }
}

private actor PermanentFailureService: GuardianPhoneService {
    private(set) var loadCount = 0

    func loadSnapshot() async throws -> GuardianPhoneSnapshot {
        loadCount += 1
        throw PhoneSecureStorageError.invalidData
    }

    func pair(code _: String) async throws {}
    func sendPrompt(_: String, to _: PhoneCommandTarget) async throws {}
    func fetchRestartImpact(for _: PhoneCommandTarget) async throws -> ImpactSnapshot {
        throw GuardianPhoneServiceError.transportUnavailable
    }
    func restartAgent(using _: ImpactSnapshot) async throws {}
}
