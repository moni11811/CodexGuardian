import CryptoKit
import Foundation
import GuardianCore
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone reconnecting remote client")
struct GuardianPhoneRemoteClientTests {
    @Test("ambiguous observe resend reuses the exact durable packet")
    func ambiguousObserveResendsExactPacket() async throws {
        let now = Date(timeIntervalSince1970: 11_000)
        let key = Curve25519.Signing.PrivateKey()
        let identity = PhoneDeviceIdentity(deviceID: UUID(), privateKey: key.rawRepresentation)
        let pairing = PhonePairedGuardian(
            guardianID: UUID(),
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: identity.deviceID,
            endpoint: .init(
                host: "192.168.1.20",
                port: 47_411,
                tlsCertificateHash: Data(repeating: 0x22, count: 32)
            ),
            capabilities: [.observe],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: now.addingTimeInterval(-100)
        )
        let backend = PhoneRemoteClientMemoryStorage()
        let sessionStorage = PhoneKeychainRemoteSessionStorage(backend: backend)
        let exchange = AmbiguousObserveExchange(now: now)
        let client = PhoneRemoteClient(
            pairingStorage: PhoneRemoteClientPairingStorage(
                identity: identity,
                pairing: pairing
            ),
            sessionStorage: sessionStorage,
            exchange: { endpoint, frame in
                try await exchange.call(endpoint: endpoint, frame: frame)
            }
        )

        await #expect(throws: AmbiguousObserveExchange.Failure.disconnected) {
            _ = try await client.observe(now: now)
        }
        let snapshot = try await client.observe(now: now.addingTimeInterval(1))

        #expect(snapshot.cursor == ProjectionCursor(generation: 7, sequence: 3))
        let frames = await exchange.frames
        #expect(frames.count == 2)
        #expect(frames[0] == frames[1])
        let record = try #require(try await sessionStorage.load(for: pairing))
        #expect(record.nextSequence == 2)
        #expect(record.pendingRequests.isEmpty)
        #expect(record.pendingAcknowledgementIDs.count == 1)
    }

    @Test("event batch is reconciled by a bounded cursorless snapshot request")
    func eventBatchTriggersAuthoritativeSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 12_000)
        let key = Curve25519.Signing.PrivateKey()
        let identity = PhoneDeviceIdentity(deviceID: UUID(), privateKey: key.rawRepresentation)
        let pairing = PhonePairedGuardian(
            guardianID: UUID(),
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: identity.deviceID,
            endpoint: .init(
                host: "192.168.1.20",
                port: 47_411,
                tlsCertificateHash: Data(repeating: 0x22, count: 32)
            ),
            capabilities: [.observe],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: now.addingTimeInterval(-100)
        )
        let backend = PhoneRemoteClientMemoryStorage()
        let sessionStorage = PhoneKeychainRemoteSessionStorage(backend: backend)
        var initial = PhoneRemoteSessionRecord.fresh(for: pairing, now: now)
        try initial.updateCursor(.init(generation: 7, sequence: 3), now: now)
        try await sessionStorage.save(initial, for: pairing)
        let exchange = EventThenSnapshotExchange(now: now)
        let client = PhoneRemoteClient(
            pairingStorage: PhoneRemoteClientPairingStorage(
                identity: identity,
                pairing: pairing
            ),
            sessionStorage: sessionStorage,
            exchange: { endpoint, frame in
                try await exchange.call(endpoint: endpoint, frame: frame)
            }
        )

        let snapshot = try await client.observe(now: now.addingTimeInterval(1))

        #expect(snapshot.cursor == ProjectionCursor(generation: 7, sequence: 4))
        let requests = await exchange.observeRequests
        #expect(requests.count == 2)
        #expect(requests[0].cursor == GuardianIPCEventCursor(generation: 7, lastSequence: 3))
        #expect(requests[1].cursor == nil)
        #expect(requests[1].acknowledgedCommandIDs.count == 1)
        let record = try #require(try await sessionStorage.load(for: pairing))
        #expect(record.cursor == ProjectionCursor(generation: 7, sequence: 4))
        #expect(record.nextSequence == 3)
        #expect(record.pendingRequests.isEmpty)
    }

    @Test("concurrent refreshes share one authenticated exchange")
    func concurrentObserveIsSingleFlight() async throws {
        let now = Date(timeIntervalSince1970: 13_000)
        let key = Curve25519.Signing.PrivateKey()
        let identity = PhoneDeviceIdentity(deviceID: UUID(), privateKey: key.rawRepresentation)
        let pairing = PhonePairedGuardian(
            guardianID: UUID(),
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: identity.deviceID,
            endpoint: .init(
                host: "192.168.1.20",
                port: 47_411,
                tlsCertificateHash: Data(repeating: 0x22, count: 32)
            ),
            capabilities: [.observe],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: now.addingTimeInterval(-100)
        )
        let exchange = BlockingObserveExchange(now: now)
        let client = PhoneRemoteClient(
            pairingStorage: PhoneRemoteClientPairingStorage(
                identity: identity,
                pairing: pairing
            ),
            sessionStorage: PhoneKeychainRemoteSessionStorage(
                backend: PhoneRemoteClientMemoryStorage()
            ),
            exchange: { endpoint, frame in
                try await exchange.call(endpoint: endpoint, frame: frame)
            }
        )

        let first = Task { try await client.observe(now: now) }
        await exchange.waitForFirstRequest()
        let second = Task { try await client.observe(now: now) }
        let duplicateStarted = await exchange.waitForRequestCount(2)
        await exchange.releaseFirstRequest()

        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value
        #expect(duplicateStarted == false)
        #expect(await exchange.requestCount == 1)
        #expect(firstSnapshot == secondSnapshot)
    }

    @Test("validated command history is returned and persisted after observe")
    func observeReturnsAndPersistsCommandHistory() async throws {
        let now = Date(timeIntervalSince1970: 12_500)
        let key = Curve25519.Signing.PrivateKey()
        let identity = PhoneDeviceIdentity(deviceID: UUID(), privateKey: key.rawRepresentation)
        let pairing = PhonePairedGuardian(
            guardianID: UUID(),
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: identity.deviceID,
            endpoint: .init(
                host: "192.168.1.20",
                port: 47_411,
                tlsCertificateHash: Data(repeating: 0x22, count: 32)
            ),
            capabilities: [.observe, .promptAgent],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: now.addingTimeInterval(-100)
        )
        let backend = PhoneRemoteClientMemoryStorage()
        let sessionStorage = PhoneKeychainRemoteSessionStorage(backend: backend)
        let historyCommandID = UUID()
        let client = PhoneRemoteClient(
            pairingStorage: PhoneRemoteClientPairingStorage(
                identity: identity,
                pairing: pairing
            ),
            sessionStorage: sessionStorage,
            exchange: { _, frame in
                let request = try GuardianRemoteWireCodec().decodeRequest(frame)
                guard case let .command(packet) = request.body else {
                    throw PhoneRemoteClientError.invalidConfiguration
                }
                let observe = packet.signedCommand.command
                let historyReceipt = GuardianRemoteReceipt(
                    commandID: historyCommandID,
                    deviceID: identity.deviceID,
                    payloadDigest: Data(repeating: 0x41, count: 32),
                    generation: 7,
                    sequence: 1,
                    acceptedAt: now.addingTimeInterval(-2)
                )
                let history = GuardianRemoteCommandHistoryItem(
                    action: .prompt,
                    targetThreadID: "thread-history",
                    expectedGeneration: 7,
                    issuedAt: now.addingTimeInterval(-3),
                    deadline: now.addingTimeInterval(20),
                    outcome: .init(receipt: historyReceipt, state: .pending),
                    outcomeVersion: 1,
                    updatedAt: now.addingTimeInterval(-2)
                )
                return try GuardianRemoteWireCodec().encode(.init(
                    protocolVersion: .current,
                    requestID: request.requestID,
                    body: .observation(.init(
                        receipt: .init(
                            commandID: observe.commandID,
                            deviceID: observe.deviceID,
                            payloadDigest: observe.payloadDigest,
                            generation: 7,
                            sequence: observe.sequence,
                            acceptedAt: now
                        ),
                        commandHistory: .init(
                            items: [history],
                            totalCount: 1,
                            completeness: .complete
                        ),
                        snapshot: GuardianIPCFullSnapshot(
                            protocolVersion: .current,
                            generation: 7,
                            lastSequence: 0,
                            capturedAt: now,
                            operations: [],
                            tasks: [],
                            taskInventoryCompleteness: .complete
                        )
                    ))
                ))
            }
        )

        let snapshot = try await client.observe(now: now)
        let persisted = try #require(try await sessionStorage.load(for: pairing))

        #expect(snapshot.commandHistory.completeness == .complete)
        #expect(snapshot.commandHistory.items.first?.outcome.commandID == historyCommandID)
        #expect(persisted.reconciledCommandHistory == snapshot.commandHistory)
    }

    @Test("cancelling the foreground observe cancels its network exchange")
    func observeCancellationStopsExchange() async throws {
        let now = Date(timeIntervalSince1970: 14_000)
        let key = Curve25519.Signing.PrivateKey()
        let identity = PhoneDeviceIdentity(deviceID: UUID(), privateKey: key.rawRepresentation)
        let pairing = PhonePairedGuardian(
            guardianID: UUID(),
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: identity.deviceID,
            endpoint: .init(
                host: "192.168.1.20",
                port: 47_411,
                tlsCertificateHash: Data(repeating: 0x22, count: 32)
            ),
            capabilities: [.observe],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: now.addingTimeInterval(-100)
        )
        let exchange = CancellableObserveExchange(now: now)
        let client = PhoneRemoteClient(
            pairingStorage: PhoneRemoteClientPairingStorage(
                identity: identity,
                pairing: pairing
            ),
            sessionStorage: PhoneKeychainRemoteSessionStorage(
                backend: PhoneRemoteClientMemoryStorage()
            ),
            exchange: { endpoint, frame in
                try await exchange.call(endpoint: endpoint, frame: frame)
            }
        )

        let observation = Task { try await client.observe(now: now) }
        await exchange.waitUntilStarted()
        observation.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await observation.value
        }
        #expect(await exchange.wasCancelled)
    }
}

private actor AmbiguousObserveExchange {
    enum Failure: Error, Equatable { case disconnected }

    private let now: Date
    private(set) var frames: [Data] = []

    init(now: Date) {
        self.now = now
    }

    func call(endpoint _: PhonePinnedEndpoint, frame: Data) throws -> Data {
        frames.append(frame)
        guard frames.count > 1 else { throw Failure.disconnected }
        let request = try GuardianRemoteWireCodec().decodeRequest(frame)
        guard case let .command(packet) = request.body else { throw Failure.disconnected }
        let command = packet.signedCommand.command
        let receipt = GuardianRemoteReceipt(
            commandID: command.commandID,
            deviceID: command.deviceID,
            payloadDigest: command.payloadDigest,
            generation: 7,
            sequence: command.sequence,
            acceptedAt: now.addingTimeInterval(1)
        )
        let snapshot = GuardianIPCFullSnapshot(
            protocolVersion: .current,
            generation: 7,
            lastSequence: 3,
            capturedAt: now.addingTimeInterval(1),
            operations: [],
            tasks: [],
            taskInventoryCompleteness: .complete
        )
        return try GuardianRemoteWireCodec().encode(.init(
            protocolVersion: .current,
            requestID: request.requestID,
            body: .observation(.init(receipt: receipt, snapshot: snapshot))
        ))
    }
}

private actor EventThenSnapshotExchange {
    private let now: Date
    private(set) var observeRequests: [GuardianRemoteObserveRequest] = []

    init(now: Date) {
        self.now = now
    }

    func call(endpoint _: PhonePinnedEndpoint, frame: Data) throws -> Data {
        let request = try GuardianRemoteWireCodec().decodeRequest(frame)
        guard case let .command(packet) = request.body else {
            throw PhoneRemoteClientError.invalidConfiguration
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let observe = try decoder.decode(
            GuardianRemoteObserveRequest.self,
            from: packet.payload
        )
        observeRequests.append(observe)
        let command = packet.signedCommand.command
        let receipt = GuardianRemoteReceipt(
            commandID: command.commandID,
            deviceID: command.deviceID,
            payloadDigest: command.payloadDigest,
            generation: 7,
            sequence: command.sequence,
            acceptedAt: now.addingTimeInterval(TimeInterval(observeRequests.count))
        )
        if observeRequests.count == 1 {
            let event = GuardianIPCEvent(
                generation: 7,
                sequence: 4,
                operationID: nil,
                emittedAt: now.addingTimeInterval(1),
                kind: .taskChanged
            )
            return try GuardianRemoteWireCodec().encode(.init(
                protocolVersion: .current,
                requestID: request.requestID,
                body: .eventBatch(.init(
                    receipt: receipt,
                    events: [event],
                    nextCursor: .init(generation: 7, lastSequence: 4)
                ))
            ))
        }
        let snapshot = GuardianIPCFullSnapshot(
            protocolVersion: .current,
            generation: 7,
            lastSequence: 4,
            capturedAt: now.addingTimeInterval(2),
            operations: [],
            tasks: [],
            taskInventoryCompleteness: .complete
        )
        return try GuardianRemoteWireCodec().encode(.init(
            protocolVersion: .current,
            requestID: request.requestID,
            body: .observation(.init(receipt: receipt, snapshot: snapshot))
        ))
    }
}

private actor BlockingObserveExchange {
    private let now: Date
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var requestCount = 0

    init(now: Date) {
        self.now = now
    }

    func waitForFirstRequest() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    func waitForRequestCount(_ desired: Int) async -> Bool {
        for _ in 0..<100 {
            if requestCount >= desired { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return requestCount >= desired
    }

    func releaseFirstRequest() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func call(endpoint _: PhonePinnedEndpoint, frame: Data) async throws -> Data {
        requestCount += 1
        if requestCount == 1 {
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        let request = try GuardianRemoteWireCodec().decodeRequest(frame)
        guard case let .command(packet) = request.body else {
            throw PhoneRemoteClientError.invalidConfiguration
        }
        let command = packet.signedCommand.command
        let receipt = GuardianRemoteReceipt(
            commandID: command.commandID,
            deviceID: command.deviceID,
            payloadDigest: command.payloadDigest,
            generation: 7,
            sequence: command.sequence,
            acceptedAt: now
        )
        let snapshot = GuardianIPCFullSnapshot(
            protocolVersion: .current,
            generation: 7,
            lastSequence: 1,
            capturedAt: now,
            operations: [],
            tasks: [],
            taskInventoryCompleteness: .complete
        )
        return try GuardianRemoteWireCodec().encode(.init(
            protocolVersion: .current,
            requestID: request.requestID,
            body: .observation(.init(receipt: receipt, snapshot: snapshot))
        ))
    }
}

private actor CancellableObserveExchange {
    private let now: Date
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = false
    private(set) var wasCancelled = false

    init(now: Date) {
        self.now = now
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func call(endpoint _: PhonePinnedEndpoint, frame: Data) async throws -> Data {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            wasCancelled = true
            throw error
        }
        let request = try GuardianRemoteWireCodec().decodeRequest(frame)
        guard case let .command(packet) = request.body else {
            throw PhoneRemoteClientError.invalidConfiguration
        }
        let command = packet.signedCommand.command
        let receipt = GuardianRemoteReceipt(
            commandID: command.commandID,
            deviceID: command.deviceID,
            payloadDigest: command.payloadDigest,
            generation: 7,
            sequence: command.sequence,
            acceptedAt: now
        )
        let snapshot = GuardianIPCFullSnapshot(
            protocolVersion: .current,
            generation: 7,
            lastSequence: 1,
            capturedAt: now,
            operations: [],
            tasks: [],
            taskInventoryCompleteness: .complete
        )
        return try GuardianRemoteWireCodec().encode(.init(
            protocolVersion: .current,
            requestID: request.requestID,
            body: .observation(.init(receipt: receipt, snapshot: snapshot))
        ))
    }
}

private actor PhoneRemoteClientPairingStorage: PhonePairingStorage {
    let identity: PhoneDeviceIdentity
    let pairing: PhonePairedGuardian

    init(identity: PhoneDeviceIdentity, pairing: PhonePairedGuardian) {
        self.identity = identity
        self.pairing = pairing
    }

    func loadOrCreateIdentity() async throws -> PhoneDeviceIdentity { identity }
    func loadPairing() async throws -> PhonePairedGuardian? { pairing }
    func save(_: PhonePairedGuardian) async throws {}
}

private final class PhoneRemoteClientMemoryStorage: PhoneSecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func write(_ data: Data, account: String) throws {
        lock.withLock { values[account] = data }
    }
}
