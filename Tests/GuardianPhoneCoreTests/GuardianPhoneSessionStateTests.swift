import Foundation
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone durable remote session")
struct GuardianPhoneSessionStateTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("exact immutable packet and next sequence survive storage recreation")
    func packetSurvivesRelaunch() async throws {
        let backend = PhoneSessionMemoryStorage()
        let pairing = pairedGuardian()
        let pending = pendingRequest(deviceID: pairing.deviceID)
        var record = PhoneRemoteSessionRecord.fresh(for: pairing, now: now)
        try record.enqueue(pending, now: now)
        let storage = PhoneKeychainRemoteSessionStorage(backend: backend)
        try await storage.save(record, for: pairing)

        let reloaded = try #require(
            try await PhoneKeychainRemoteSessionStorage(backend: backend).load(for: pairing)
        )
        #expect(reloaded.pendingRequests == [pending])
        #expect(reloaded.pendingRequests[0].frame == pending.frame)
        #expect(reloaded.nextSequence == 2)
    }

    @Test("terminal outcome remains ACK-pending until matching server acknowledgement")
    func lostAckSurvivesRelaunch() async throws {
        let backend = PhoneSessionMemoryStorage()
        let pairing = pairedGuardian()
        let pending = pendingRequest(deviceID: pairing.deviceID)
        var record = PhoneRemoteSessionRecord.fresh(for: pairing, now: now)
        try record.enqueue(pending, now: now)
        try record.record(
            .init(
                commandID: pending.commandID,
                deviceID: pending.deviceID,
                payloadDigest: pending.payloadDigest,
                generation: 7,
                sequence: pending.sequence,
                acceptedAt: now,
                state: .applied(at: now.addingTimeInterval(1))
            ),
            now: now.addingTimeInterval(1)
        )
        #expect(record.pendingAcknowledgementIDs == [pending.commandID])
        let storage = PhoneKeychainRemoteSessionStorage(backend: backend)
        try await storage.save(record, for: pairing)

        var reloaded = try #require(try await storage.load(for: pairing))
        try reloaded.applyAcknowledgements([], now: now.addingTimeInterval(2))
        #expect(reloaded.pendingAcknowledgementIDs == [pending.commandID])
        try reloaded.applyAcknowledgements([
            .init(
                commandID: pending.commandID,
                deviceID: pairing.deviceID,
                outcomeVersion: 2,
                acknowledgedAt: now.addingTimeInterval(2)
            ),
        ], now: now.addingTimeInterval(2))
        #expect(reloaded.pendingAcknowledgementIDs.isEmpty)
    }

    @Test("corrupt persisted session fails closed instead of resetting sequence")
    func corruptSessionFailsClosed() async throws {
        let backend = PhoneSessionMemoryStorage()
        try backend.write(Data("not-json".utf8), account: PhoneKeychainRemoteSessionStorage.account)

        await #expect(throws: PhoneSecureStorageError.invalidData) {
            _ = try await PhoneKeychainRemoteSessionStorage(backend: backend)
                .load(for: pairedGuardian())
        }
    }

    @Test("reconnect keeps an authoritative pending command accepted, never applied")
    func reconnectMergesAuthoritativeHistoryWithoutUpgradingPendingToApplied() throws {
        let pairing = pairedGuardian()
        let pending = pendingRequest(deviceID: pairing.deviceID)
        var record = PhoneRemoteSessionRecord.fresh(for: pairing, now: now)
        try record.enqueue(pending, now: now)
        let accepted = PhoneRemoteCommandOutcome(
            commandID: pending.commandID,
            deviceID: pending.deviceID,
            payloadDigest: pending.payloadDigest,
            generation: 7,
            sequence: pending.sequence,
            acceptedAt: now,
            state: .accepted
        )
        try record.record(accepted, now: now)
        try record.mergeCommandHistory(
            PhoneRemoteCommandHistoryPage(
                items: [historyItem(for: pending, outcome: accepted, version: 1, updatedAt: now)],
                totalCount: 1,
                completeness: .complete
            ),
            now: now.addingTimeInterval(1)
        )

        let item = try #require(record.reconciledCommandHistory.items.first)
        #expect(item.outcome.state == .accepted)
        #expect(PhoneCommandRecord(
            id: OperationID(item.outcome.commandID.uuidString),
            action: .promptAgent,
            state: item.outcome.state,
            createdAt: item.issuedAt
        ).presentation == .acceptedByGuardian)
    }

    @Test("an older reconnect page cannot downgrade a terminal outcome")
    func olderHistoryCannotDowngradeTerminalOutcome() throws {
        let pairing = pairedGuardian()
        let pending = pendingRequest(deviceID: pairing.deviceID)
        var record = PhoneRemoteSessionRecord.fresh(for: pairing, now: now)
        try record.enqueue(pending, now: now)
        let appliedAt = now.addingTimeInterval(1)
        let applied = PhoneRemoteCommandOutcome(
            commandID: pending.commandID,
            deviceID: pending.deviceID,
            payloadDigest: pending.payloadDigest,
            generation: 7,
            sequence: pending.sequence,
            acceptedAt: now,
            state: .applied(at: appliedAt)
        )
        try record.record(applied, now: appliedAt)
        let olderAccepted = PhoneRemoteCommandOutcome(
            commandID: pending.commandID,
            deviceID: pending.deviceID,
            payloadDigest: pending.payloadDigest,
            generation: 7,
            sequence: pending.sequence,
            acceptedAt: now,
            state: .accepted
        )
        try record.mergeCommandHistory(
            PhoneRemoteCommandHistoryPage(
                items: [historyItem(
                    for: pending,
                    outcome: olderAccepted,
                    version: 1,
                    updatedAt: now
                )],
                totalCount: 1,
                completeness: .complete
            ),
            now: now.addingTimeInterval(2)
        )

        #expect(record.reconciledCommandHistory.items.first?.outcome.state == .applied(at: appliedAt))
        #expect(record.reconciledCommandHistory.items.first?.outcomeVersion == 2)
    }

    private func pairedGuardian() -> PhonePairedGuardian {
        PhonePairedGuardian(
            guardianID: UUID(uuidString: "90000000-0000-0000-0000-000000000001")!,
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: UUID(uuidString: "90000000-0000-0000-0000-000000000002")!,
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
    }

    private func pendingRequest(deviceID: UUID) -> PhonePendingRemoteRequest {
        PhonePendingRemoteRequest(
            requestID: UUID(uuidString: "90000000-0000-0000-0000-000000000003")!,
            commandID: UUID(uuidString: "90000000-0000-0000-0000-000000000004")!,
            deviceID: deviceID,
            expectedGeneration: 7,
            sequence: 1,
            nonce: UUID(uuidString: "90000000-0000-0000-0000-000000000005")!,
            targetThreadID: "thread-1",
            action: .promptAgent,
            payloadDigest: Data(repeating: 0x33, count: 32),
            frame: Data([0, 0, 0, 1, 0x7b]),
            issuedAt: now,
            deadline: now.addingTimeInterval(30)
        )
    }

    private func historyItem(
        for pending: PhonePendingRemoteRequest,
        outcome: PhoneRemoteCommandOutcome,
        version: Int64,
        updatedAt: Date
    ) -> PhoneRemoteCommandHistoryItem {
        PhoneRemoteCommandHistoryItem(
            action: .prompt,
            targetThreadID: pending.targetThreadID,
            expectedGeneration: pending.expectedGeneration,
            issuedAt: pending.issuedAt,
            deadline: pending.deadline,
            outcome: outcome,
            outcomeVersion: version,
            updatedAt: updatedAt
        )
    }
}

private final class PhoneSessionMemoryStorage: PhoneSecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func write(_ data: Data, account: String) throws {
        lock.withLock { values[account] = data }
    }
}
