import Foundation
import Testing
@testable import GuardianCore

@Suite(.serialized)
struct GuardianNativeRecoveryAcknowledgerTests {
    @Test func exactOriginAcknowledgesReceiptAndRetryIsIdempotent() async throws {
        let fixture = try Fixture()
        let prepared = try await fixture.prepareDeliveredRecovery()

        let first = try fixture.acknowledger.acknowledge(
            originToken: fixture.originToken.uuidString
        )
        let second = try fixture.acknowledger.acknowledge(
            originToken: fixture.originToken.uuidString
        )

        #expect(!first.alreadyAcknowledged)
        #expect(second.alreadyAcknowledged)
        #expect(first.operationID == prepared.operationID)
        #expect(first.threadID == "thread-ack")
        #expect(first.turnID == "turn-ack")
        #expect(first.messageItemID == "item-ack")
        #expect(try fixture.store.request(
            originToken: fixture.originToken.uuidString
        ) == nil)
        #expect(try fixture.journal.operation(id: prepared.operationID)?.phase
            == .acknowledged)
        let entries = try fixture.journal.outboxEntries(
            operationID: prepared.operationID
        )
        let entry = try #require(entries.first)
        #expect(entry.state == .acknowledged)
        #expect(entry.sealedPayload.isEmpty)
    }

    @Test func wrongOriginCannotAcknowledgeAnotherRecovery() async throws {
        let fixture = try Fixture()
        _ = try await fixture.prepareDeliveredRecovery()

        #expect(throws: GuardianNativeRecoveryAcknowledgementError.requestNotFound) {
            try fixture.acknowledger.acknowledge(originToken: UUID().uuidString)
        }
    }

    private struct Fixture {
        let originToken = UUID(
            uuidString: "7AC3850D-8CF4-4431-B629-02CA07268CE8"
        )!
        let journal: GuardianJournal
        let store: RestartRequestStore
        let outbox: GuardianProtectedOutbox
        let registrar: GuardianNativeRecoveryRegistrar
        let acknowledger: GuardianNativeRecoveryAcknowledger

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "guardian-native-ack-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            journal = try GuardianJournal(
                databaseURL: directory.appending(path: "guardian.sqlite")
            )
            store = RestartRequestStore(directory: directory)
            let key = Data(repeating: 0x7C, count: 32)
            let manager = GuardianParentKeyManager(
                storage: AcknowledgementSecretStorage(key: key),
                generator: { key }
            )
            outbox = GuardianProtectedOutbox(journal: journal, keyManager: manager)
            registrar = GuardianNativeRecoveryRegistrar(journal: journal, outbox: outbox)
            acknowledger = GuardianNativeRecoveryAcknowledger(
                journal: journal,
                store: store
            )
        }

        func prepareDeliveredRecovery() async throws -> GuardianNativeRecoveryRegistration {
            let request = RestartRequest(
                threadID: "thread-ack",
                recoveryPrompt: "Continue and acknowledge after progress.",
                originToken: originToken.uuidString,
                requestMode: .nativeFirst
            )
            try store.enqueue(request)
            try store.claimPending(ids: [request.id])
            let registration = try await registrar.register(
                originToken: originToken,
                threadID: request.threadID,
                recoveryPrompt: request.recoveryPrompt
            )
            try store.markClaimNativeExecuting(
                id: request.id,
                operationID: registration.operationID,
                generation: registration.generation
            )
            _ = try journal.beginOutboxDeliveryAttempt(
                messageID: registration.operationID
            )
            try journal.recordDeliveryReceipt(GuardianDeliveryReceipt(
                operationID: registration.operationID,
                messageID: registration.operationID,
                targetThreadID: request.threadID,
                messageItemID: "item-ack",
                turnID: "turn-ack",
                acceptedAt: Date().addingTimeInterval(1)
            ))
            try store.markNativeAwaitingAcknowledgement(id: request.id)
            return registration
        }
    }
}

private struct AcknowledgementSecretStorage: GuardianSecretStorage {
    let key: Data
    func read(service: String, account: String) throws -> Data? { key }
    func insert(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}
