import Foundation
import Testing
@testable import GuardianCore

@Suite(.serialized)
struct GuardianNativeRecoveryExecutorTests {
    @Test func appExecutionPersistsAttemptExactReceiptAndAckWait() async throws {
        let fixture = try Fixture()
        let request = fixture.nativeRequest()
        try fixture.store.enqueue(request)
        try fixture.store.claimPending(ids: [request.id])
        let clientID = CodexAppServerRecoveryProtocol.clientMessageID(
            originToken: fixture.originToken,
            generation: 1
        )
        let transport = ExecutorRecoveryTransport(
            responses: [
                Data(#"{"id":1,"result":{"userAgent":"test"}}"#.utf8),
                Data(#"{"id":2,"result":{"thread":{"id":"thread-native","turns":[]}}}"#.utf8),
                Data(#"{"id":3,"result":{"thread":{"id":"thread-native","turns":[]}}}"#.utf8),
                Data(#"{"id":4,"result":{"turn":{"id":"turn-native","status":"inProgress","items":[]}}}"#.utf8),
                Data("""
                {"id":5,"result":{"thread":{"id":"thread-native","turns":[
                  {"id":"turn-native","items":[
                    {"type":"userMessage","id":"item-native","clientId":"\(clientID)"}
                  ]}
                ]}}}
                """.utf8),
            ],
            notifications: [
                Data(#"{"method":"turn/completed","params":{"threadId":"thread-native","turn":{"id":"turn-native","status":"completed","items":[]}}}"#.utf8),
            ]
        )

        let result = try await fixture.executor.execute(
            request: request,
            transport: transport,
            deadline: Date().addingTimeInterval(5)
        )

        guard case let .delivered(registration, delivery, alreadySubmitted) = result else {
            Issue.record("Expected delivered native recovery")
            return
        }
        #expect(!alreadySubmitted)
        #expect(delivery.threadID == request.threadID)
        #expect(delivery.turnID == "turn-native")
        #expect(delivery.userMessageItemID == "item-native")
        let maybeStoredRequest = try fixture.store.request(
            originToken: fixture.originToken.uuidString
        )
        let storedRequest = try #require(maybeStoredRequest)
        #expect(storedRequest.recoveryPhase == .nativeAwaitingAcknowledgement)
        #expect(storedRequest.nativeOperationID == registration.operationID)
        #expect(try fixture.journal.operation(id: registration.operationID)?.phase
            == .deliveryReceipt)
        let outboxEntries = try fixture.journal.outboxEntries(
            operationID: registration.operationID
        )
        let outbox = try #require(outboxEntries.first)
        #expect(outbox.state == .accepted)
        #expect(outbox.receipt?.targetThreadID == request.threadID)
        #expect(outbox.receipt?.messageItemID == "item-native")
        #expect(outbox.receipt?.turnID == "turn-native")
        #expect(transport.recoveryPrompt()?.contains("ack_recovery") == true)
        #expect(transport.recoveryPrompt()?.contains(fixture.originToken.uuidString) == true)
        #expect(transport.requestMethods() == [
            "initialize", "thread/resume", "thread/read", "turn/start", "thread/read",
        ])
    }

    @Test func receiptSurvivesCrashBeforeRequestStateUpdateWithoutResending() async throws {
        let fixture = try Fixture()
        let request = fixture.nativeRequest()
        try fixture.store.enqueue(request)
        try fixture.store.claimPending(ids: [request.id])
        let registration = try await fixture.registrar.register(
            originToken: fixture.originToken,
            threadID: request.threadID,
            recoveryPrompt: request.recoveryPrompt
        )
        try fixture.store.markClaimNativeExecuting(
            id: request.id,
            operationID: registration.operationID,
            generation: registration.generation
        )
        _ = try fixture.journal.beginOutboxDeliveryAttempt(
            messageID: registration.operationID
        )
        let receipt = GuardianDeliveryReceipt(
            operationID: registration.operationID,
            messageID: registration.operationID,
            targetThreadID: request.threadID,
            messageItemID: "item-before-crash",
            turnID: "turn-before-crash",
            acceptedAt: Date().addingTimeInterval(1)
        )
        try fixture.journal.recordDeliveryReceipt(receipt)
        let transport = ExecutorRecoveryTransport(responses: [], notifications: [])

        let result = try await fixture.executor.execute(
            request: request,
            transport: transport,
            deadline: Date().addingTimeInterval(5)
        )

        guard case let .delivered(_, delivery, alreadySubmitted) = result else {
            Issue.record("Expected persisted delivery after crash recovery")
            return
        }
        #expect(alreadySubmitted)
        #expect(delivery.threadID == receipt.targetThreadID)
        #expect(delivery.turnID == receipt.turnID)
        #expect(delivery.userMessageItemID == receipt.messageItemID)
        #expect(transport.requestMethods().isEmpty)
        let stored = try fixture.store.request(
            originToken: fixture.originToken.uuidString
        )
        #expect(stored?.recoveryPhase == .nativeAwaitingAcknowledgement)
    }

    private struct Fixture {
        let originToken = UUID(uuidString: "D0EB594A-25C6-43B5-A1C7-7AB151DF1A21")!
        let journal: GuardianJournal
        let store: RestartRequestStore
        let outbox: GuardianProtectedOutbox
        let registrar: GuardianNativeRecoveryRegistrar
        let executor: GuardianNativeRecoveryExecutor

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "guardian-native-executor-\(UUID().uuidString)")
            journal = try GuardianJournal(
                databaseURL: directory.appending(path: "guardian.sqlite")
            )
            store = RestartRequestStore(directory: directory)
            let key = Data(repeating: 0x6B, count: 32)
            let keyManager = GuardianParentKeyManager(
                storage: ExecutorSecretStorage(key: key),
                generator: { key }
            )
            outbox = GuardianProtectedOutbox(
                journal: journal,
                keyManager: keyManager
            )
            registrar = GuardianNativeRecoveryRegistrar(
                journal: journal,
                outbox: outbox
            )
            executor = GuardianNativeRecoveryExecutor(
                journal: journal,
                outbox: outbox,
                store: store
            )
        }

        func nativeRequest() -> RestartRequest {
            RestartRequest(
                threadID: "thread-native",
                recoveryPrompt: "Continue through the changed route.",
                originToken: originToken.uuidString,
                requestMode: .nativeFirst
            )
        }
    }
}

private struct ExecutorSecretStorage: GuardianSecretStorage {
    let key: Data
    func read(service: String, account: String) throws -> Data? { key }
    func insert(_ data: Data, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private final class ExecutorRecoveryTransport: @unchecked Sendable,
    CodexAppServerRecoveryTransport {
    private let lock = NSLock()
    private var responses: [Data]
    private var notifications: [Data]
    private var requests: [Data] = []

    init(responses: [Data], notifications: [Data]) {
        self.responses = responses
        self.notifications = notifications
    }

    func exchange(request: Data, deadline: Date) throws -> Data {
        try lock.withLock {
            requests.append(request)
            guard !responses.isEmpty else { throw ExecutorTransportError.exhausted }
            return responses.removeFirst()
        }
    }

    func send(notification: Data, deadline: Date) throws {}

    func receive(deadline: Date) throws -> Data {
        try lock.withLock {
            guard !notifications.isEmpty else { throw ExecutorTransportError.exhausted }
            return notifications.removeFirst()
        }
    }

    func requestMethods() -> [String] {
        lock.withLock { requests.compactMap(Self.method) }
    }

    func recoveryPrompt() -> String? {
        lock.withLock {
            guard let request = requests.first(where: { Self.method($0) == "turn/start" }),
                  let object = try? JSONSerialization.jsonObject(with: request)
                    as? [String: Any],
                  let params = object["params"] as? [String: Any],
                  let input = params["input"] as? [[String: Any]] else { return nil }
            return input.first?["text"] as? String
        }
    }

    private static func method(_ data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["method"] as? String
    }
}

private enum ExecutorTransportError: Error {
    case exhausted
}
