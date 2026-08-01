import Foundation
import Testing
@testable import GuardianCore

@Suite(.serialized)
struct GuardianNativeRecoveryRegistrarTests {
    @Test func registrationDurablyQueuesOneEncryptedIdempotentContinuation() async throws {
        let fixture = try Fixture()
        let originToken = try #require(
            UUID(uuidString: "D0EB594A-25C6-43B5-A1C7-7AB151DF1A21")
        )

        let first = try await fixture.registrar.register(
            originToken: originToken,
            threadID: "thread-native",
            recoveryPrompt: "Continue through the changed fallback.",
            at: fixture.now
        )
        let second = try await fixture.registrar.register(
            originToken: originToken,
            threadID: "thread-native",
            recoveryPrompt: "Continue through the changed fallback.",
            at: fixture.now.addingTimeInterval(1)
        )

        #expect(second == first)
        #expect(first.generation == 1)
        #expect(try fixture.journal.operation(id: first.operationID)?.phase
            == .continuationSent)
        let entries = try fixture.journal.outboxEntries(operationID: first.operationID)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.sealedPayload != Data("Continue through the changed fallback.".utf8))

        let opened = try await fixture.outbox.open(entry)
        let envelope = try JSONDecoder().decode(
            GuardianNativeRecoveryEnvelope.self,
            from: opened
        )
        #expect(envelope.originToken == originToken)
        #expect(envelope.generation == 1)
        #expect(envelope.recoveryPrompt == "Continue through the changed fallback.")
        #expect(try fixture.journal.events(operationID: first.operationID).map(\.phase)
            == [.prepared, .targetLoaded, .continuationSent])
    }

    @Test func reusedOriginCannotRetargetOrChangePrompt() async throws {
        let fixture = try Fixture()
        let originToken = UUID()
        _ = try await fixture.registrar.register(
            originToken: originToken,
            threadID: "thread-native",
            recoveryPrompt: "Original prompt",
            at: fixture.now
        )

        await #expect(throws: (any Error).self) {
            try await fixture.registrar.register(
                originToken: originToken,
                threadID: "other-thread",
                recoveryPrompt: "Original prompt",
                at: fixture.now.addingTimeInterval(1)
            )
        }
        await #expect(throws: (any Error).self) {
            try await fixture.registrar.register(
                originToken: originToken,
                threadID: "thread-native",
                recoveryPrompt: "Changed prompt",
                at: fixture.now.addingTimeInterval(1)
            )
        }
    }

    private struct Fixture {
        let now = Date(timeIntervalSince1970: 70_000)
        let journal: GuardianJournal
        let outbox: GuardianProtectedOutbox
        let registrar: GuardianNativeRecoveryRegistrar

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "guardian-native-registration-\(UUID().uuidString)")
            journal = try GuardianJournal(
                databaseURL: directory.appending(path: "guardian.sqlite")
            )
            let key = Data(repeating: 0x5A, count: 32)
            let manager = GuardianParentKeyManager(
                storage: RegistrationSecretStorage(key: key),
                generator: { key }
            )
            outbox = GuardianProtectedOutbox(journal: journal, keyManager: manager)
            registrar = GuardianNativeRecoveryRegistrar(journal: journal, outbox: outbox)
        }
    }
}

private struct RegistrationSecretStorage: GuardianSecretStorage {
    let key: Data

    func read(service: String, account: String) throws -> Data? { key }
    func insert(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}
