import Foundation
import GRDB

extension GuardianJournal {
    public func appendDaemonEvent(
        kind: GuardianIPCEventKind,
        operationID: UUID?,
        expectedGeneration: Int64,
        at date: Date = Date()
    ) throws -> GuardianIPCEvent {
        guard expectedGeneration > 0,
              date.timeIntervalSince1970.isFinite,
              (kind == .operationChanged) == (operationID != nil) else {
            throw GuardianJournalError.invalidProjectionRecord
        }
        return try database.write { database in
            guard let state = try Row.fetchOne(
                database,
                sql: "SELECT generation, last_sequence FROM guardian_daemon_state WHERE singleton_id = 1"
            ) else {
                throw GuardianJournalError.storageUnavailable
            }
            let generation: Int64 = state["generation"]
            let lastSequence: Int64 = state["last_sequence"]
            guard generation == expectedGeneration else {
                throw GuardianJournalError.staleDaemonGeneration(
                    expected: expectedGeneration,
                    current: generation
                )
            }
            guard lastSequence >= 0,
                  lastSequence < Int64.max else {
                throw GuardianJournalError.storageUnavailable
            }
            let event = GuardianIPCEvent(
                generation: generation,
                sequence: lastSequence + 1,
                operationID: operationID,
                emittedAt: date,
                kind: kind
            )
            try database.execute(
                sql: """
                INSERT INTO guardian_daemon_events
                    (generation, sequence, operation_id, emitted_at, kind)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    event.generation,
                    event.sequence,
                    event.operationID?.uuidString,
                    event.emittedAt.timeIntervalSince1970,
                    event.kind.rawValue,
                ]
            )
            faultInjector?(.daemonEventInsertedBeforeSequenceAdvance)
            try database.execute(
                sql: """
                UPDATE guardian_daemon_state
                SET last_sequence = ?, updated_at = ?
                WHERE singleton_id = 1 AND generation = ? AND last_sequence = ?
                """,
                arguments: [
                    event.sequence,
                    event.emittedAt.timeIntervalSince1970,
                    generation,
                    lastSequence,
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.staleDaemonGeneration(
                    expected: generation,
                    current: generation
                )
            }
            return event
        }
    }

    public func replayDaemonEvents(
        after cursor: GuardianIPCEventCursor,
        limit: Int = 100
    ) throws -> GuardianDaemonEventReplay {
        guard cursor.generation > 0,
              cursor.lastSequence >= 0,
              (1...1_000).contains(limit) else {
            throw GuardianJournalError.invalidProjectionRecord
        }
        return try database.read { database in
            guard let state = try Row.fetchOne(
                database,
                sql: "SELECT generation, last_sequence FROM guardian_daemon_state WHERE singleton_id = 1"
            ) else {
                throw GuardianJournalError.storageUnavailable
            }
            let generation: Int64 = state["generation"]
            let lastSequence: Int64 = state["last_sequence"]
            guard generation == cursor.generation else {
                return .snapshotRequired(.generationChanged(
                    expected: cursor.generation,
                    received: generation
                ))
            }
            guard cursor.lastSequence <= lastSequence else {
                return .snapshotRequired(.sequenceGap(
                    expected: cursor.lastSequence + 1,
                    received: lastSequence + 1
                ))
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT generation, sequence, operation_id, emitted_at, kind
                FROM guardian_daemon_events
                WHERE generation = ? AND sequence > ?
                ORDER BY sequence
                LIMIT ?
                """,
                arguments: [generation, cursor.lastSequence, limit]
            )
            let events = try rows.map(Self.decodeDaemonEvent)
            if cursor.lastSequence < lastSequence,
               events.isEmpty {
                return .snapshotRequired(.sequenceGap(
                    expected: cursor.lastSequence + 1,
                    received: lastSequence
                ))
            }
            var expected = cursor.lastSequence + 1
            for event in events {
                guard event.sequence == expected else {
                    return .snapshotRequired(.sequenceGap(
                        expected: expected,
                        received: event.sequence
                    ))
                }
                expected += 1
            }
            return .events(
                events,
                nextCursor: GuardianIPCEventCursor(
                    generation: generation,
                    lastSequence: events.last?.sequence ?? cursor.lastSequence
                )
            )
        }
    }

    private static func decodeDaemonEvent(_ row: Row) throws -> GuardianIPCEvent {
        let generation: Int64 = row["generation"]
        let sequence: Int64 = row["sequence"]
        let operationText: String? = row["operation_id"]
        let emittedAt: Double = row["emitted_at"]
        let kindText: String = row["kind"]
        guard generation > 0,
              sequence > 0,
              emittedAt.isFinite,
              let kind = GuardianIPCEventKind(rawValue: kindText) else {
            throw GuardianJournalError.storageUnavailable
        }
        let operationID = try operationText.map { value -> UUID in
            guard let id = UUID(uuidString: value) else {
                throw GuardianJournalError.storageUnavailable
            }
            return id
        }
        guard (kind == .operationChanged) == (operationID != nil) else {
            throw GuardianJournalError.storageUnavailable
        }
        return GuardianIPCEvent(
            generation: generation,
            sequence: sequence,
            operationID: operationID,
            emittedAt: Date(timeIntervalSince1970: emittedAt),
            kind: kind
        )
    }
}
