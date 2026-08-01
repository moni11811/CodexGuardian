import Foundation
import GuardianPhoneCore
import Testing
@testable import CodexGuardianPhone

struct GuardianPhoneServiceTests {
    @Test("production pairing invokes the secure pairing action with the exact code")
    func productionPairingUsesSecureAction() async throws {
        let recorder = PairingCodeRecorder()
        let service = ProductionGuardianPhoneService(pairing: { code in
            await recorder.record(code)
        })

        try await service.pair(code: "codexguardian://pair?payload=test")

        #expect(await recorder.code == "codexguardian://pair?payload=test")
    }

    @Test("production snapshot loads through the authenticated remote client")
    func productionSnapshotUsesRemoteClient() async throws {
        let now = Date(timeIntervalSince1970: 13_000)
        let remote = PhoneRemoteSnapshot(
            cursor: .init(generation: 8, sequence: 2),
            capturedAt: now,
            inventoryCompleteness: .complete,
            tasks: []
        )
        let service = ProductionGuardianPhoneService(
            pairing: { _ in },
            observe: { remote }
        )

        let snapshot = try await service.loadSnapshot()

        #expect(snapshot.serverGeneration == 8)
        #expect(snapshot.capabilities.first(where: { $0.action == .observe })?.isActionable == true)
    }
}

private actor PairingCodeRecorder {
    private(set) var code: String?

    func record(_ code: String) {
        self.code = code
    }
}
