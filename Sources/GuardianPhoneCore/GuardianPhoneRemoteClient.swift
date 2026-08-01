import Foundation

public enum PhoneRemoteClientError: Error, Equatable, Sendable {
    case notPaired
    case invalidConfiguration
    case pendingMutationRequiresReconciliation
    case snapshotRequired
}

public actor PhoneRemoteClient {
    public typealias Exchange = @Sendable (
        PhonePinnedEndpoint,
        Data
    ) async throws -> Data

    private let pairingStorage: any PhonePairingStorage
    private let sessionStorage: PhoneKeychainRemoteSessionStorage
    private let exchange: Exchange
    private let requestLifetime: TimeInterval
    private let codec: PhoneRemoteOperationalCodec
    private var activeObservation: Task<PhoneRemoteSnapshot, Error>?

    public init(
        pairingStorage: any PhonePairingStorage,
        sessionStorage: PhoneKeychainRemoteSessionStorage,
        requestLifetime: TimeInterval = 10,
        codec: PhoneRemoteOperationalCodec = PhoneRemoteOperationalCodec(),
        exchange: @escaping Exchange
    ) {
        self.pairingStorage = pairingStorage
        self.sessionStorage = sessionStorage
        self.requestLifetime = requestLifetime
        self.codec = codec
        self.exchange = exchange
    }

    public func observe(now: Date = Date()) async throws -> PhoneRemoteSnapshot {
        if let activeObservation {
            return try await awaitObservation(activeObservation)
        }
        let task = Task { try await self.performObserve(now: now) }
        activeObservation = task
        do {
            let snapshot = try await awaitObservation(task)
            activeObservation = nil
            return snapshot
        } catch {
            activeObservation = nil
            throw error
        }
    }

    private func awaitObservation(
        _ task: Task<PhoneRemoteSnapshot, Error>
    ) async throws -> PhoneRemoteSnapshot {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performObserve(now: Date) async throws -> PhoneRemoteSnapshot {
        guard requestLifetime > 0,
              requestLifetime.isFinite,
              now.timeIntervalSince1970.isFinite else {
            throw PhoneRemoteClientError.invalidConfiguration
        }
        guard let pairing = try await pairingStorage.loadPairing() else {
            throw PhoneRemoteClientError.notPaired
        }
        let identity = try await pairingStorage.loadOrCreateIdentity()
        var record = try await sessionStorage.load(for: pairing)
            ?? PhoneRemoteSessionRecord.fresh(for: pairing, now: now)
        for reconciliationAttempt in 0..<2 {
            let requestCursor = record.cursor
            let pending: PhonePendingRemoteRequest
            if let existing = record.pendingRequests.first {
                guard existing.action == .observe else {
                    throw PhoneRemoteClientError.pendingMutationRequiresReconciliation
                }
                pending = existing
            } else {
                pending = try codec.makeObserveRequest(
                    identity: identity,
                    pairing: pairing,
                    expectedGeneration: requestCursor?.generation ?? 0,
                    sequence: record.nextSequence,
                    cursor: requestCursor,
                    acknowledgedCommandIDs: record.pendingAcknowledgementIDs,
                    now: now,
                    deadline: now.addingTimeInterval(requestLifetime)
                )
                try record.enqueue(pending, now: now)
                try await sessionStorage.save(record, for: pairing)
            }

            let responseFrame = try await exchange(pairing.endpoint, pending.frame)
            let response = try codec.decodeObserveResponse(
                responseFrame,
                expectedRequestID: pending.requestID,
                expectedCommandID: pending.commandID,
                expectedDeviceID: pairing.deviceID,
                expectedPayloadDigest: pending.payloadDigest,
                expectedCursor: requestCursor
            )
            try record.record(response.outcome, now: now)
            try record.applyAcknowledgements(response.acknowledgements, now: now)
            try record.mergeCommandHistory(response.commandHistory, now: now)
            switch response.payload {
            case let .snapshot(snapshot):
                try record.updateCursor(snapshot.cursor, now: now)
                try await sessionStorage.save(record, for: pairing)
                return snapshot.replacingCommandHistory(
                    with: record.reconciledCommandHistory
                )
            case .eventsRequireSnapshot:
                guard reconciliationAttempt == 0 else {
                    try await sessionStorage.save(record, for: pairing)
                    throw PhoneRemoteClientError.snapshotRequired
                }
                try record.requireAuthoritativeSnapshot(now: now)
                try await sessionStorage.save(record, for: pairing)
            }
        }
        throw PhoneRemoteClientError.snapshotRequired
    }
}

public extension PhoneRemoteClient {
    static func production() -> PhoneRemoteClient {
        let pairingStorage = PhoneKeychainPairingStorage()
        let transport = PhonePinnedTLSExchange()
        return PhoneRemoteClient(
            pairingStorage: pairingStorage,
            sessionStorage: PhoneKeychainRemoteSessionStorage(),
            exchange: { endpoint, frame in
                try await transport(endpoint: endpoint, requestFrame: frame)
            }
        )
    }
}
