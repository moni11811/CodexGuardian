import Foundation

public actor GuardianProtectedOutbox {
    private let journal: GuardianJournal
    private let keyManager: GuardianParentKeyManager

    public init(
        journal: GuardianJournal,
        keyManager: GuardianParentKeyManager = GuardianParentKeyManager()
    ) {
        self.journal = journal
        self.keyManager = keyManager
    }

    @discardableResult
    public func enqueue(
        operationID: UUID,
        targetThreadID: String,
        plaintext: Data,
        at date: Date = Date()
    ) async throws -> GuardianOutboxEntry {
        let cipher = try await cipher()
        if let existing = try journal.outboxEntries(operationID: operationID).first {
            return try verifyExisting(
                existing,
                targetThreadID: targetThreadID,
                plaintext: plaintext,
                cipher: cipher
            )
        }

        let entry = GuardianOutboxEntry(
            operationID: operationID,
            messageID: operationID,
            targetThreadID: targetThreadID,
            sealedPayload: try cipher.seal(plaintext, for: operationID),
            state: .pending,
            attemptCount: 0,
            createdAt: date,
            updatedAt: date,
            receipt: nil
        )
        do {
            try journal.enqueueContinuation(entry)
            return entry
        } catch GuardianJournalError.outboxConflict {
            guard let existing = try journal.outboxEntries(operationID: operationID).first else {
                throw GuardianJournalError.outboxConflict(operationID)
            }
            return try verifyExisting(
                existing,
                targetThreadID: targetThreadID,
                plaintext: plaintext,
                cipher: cipher
            )
        }
    }

    public func open(_ entry: GuardianOutboxEntry) async throws -> Data {
        try await cipher().open(entry.sealedPayload, for: entry.operationID)
    }

    private func cipher() async throws -> GuardianPayloadCipher {
        try await GuardianPayloadCipher(parentKeyData: keyManager.loadOrCreate())
    }

    private func verifyExisting(
        _ entry: GuardianOutboxEntry,
        targetThreadID: String,
        plaintext: Data,
        cipher: GuardianPayloadCipher
    ) throws -> GuardianOutboxEntry {
        guard entry.targetThreadID == targetThreadID,
              try cipher.open(entry.sealedPayload, for: entry.operationID) == plaintext else {
            throw GuardianJournalError.outboxConflict(entry.operationID)
        }
        return entry
    }
}
