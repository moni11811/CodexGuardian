import Foundation
import GRDB

public final class GuardianJournal: @unchecked Sendable {
    let database: DatabasePool
    private let databaseURL: URL
    private let transitionPolicy = GuardianOperationTransitionPolicy()
    let faultInjector: GuardianJournalFaultInjector?

    public init(
        databaseURL: URL,
        faultInjector: GuardianJournalFaultInjector? = nil
    ) throws {
        self.databaseURL = databaseURL
        self.faultInjector = faultInjector
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw GuardianJournalError.storageUnavailable
        }

        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        do {
            database = try DatabasePool(
                path: databaseURL.path,
                configuration: configuration
            )
            try Self.secureStorageFiles(databaseURL: databaseURL)
        } catch {
            throw GuardianJournalError.storageUnavailable
        }

        var migrator = DatabaseMigrator()
        migrator.registerMigration("guardian-journal-v1") { database in
            try database.create(table: "guardian_operations") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull()
                table.column("origin_thread_id", .text).notNull()
                table.column("origin_token_hash", .text).notNull()
                table.column("phase", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
            }
            try database.create(table: "guardian_operation_events") { table in
                table.column("operation_id", .text)
                    .notNull()
                    .references("guardian_operations", onDelete: .cascade)
                table.column("event_index", .integer).notNull()
                table.column("phase", .text).notNull()
                table.column("occurred_at", .double).notNull()
                table.primaryKey(["operation_id", "event_index"])
            }
        }
        migrator.registerMigration("guardian-journal-v2-fencing") { database in
            try database.create(
                index: "guardian_operations_origin_token",
                on: "guardian_operations",
                columns: ["origin_token_hash"],
                unique: true
            )
            try database.create(table: "guardian_leases") { table in
                table.column("resource", .text).primaryKey()
                table.column("owner_id", .text).notNull()
                table.column("generation", .integer).notNull()
                table.column("expires_at", .double).notNull()
                table.column("updated_at", .double).notNull()
            }
        }
        migrator.registerMigration("guardian-journal-v3-outbox") { database in
            try database.create(table: "guardian_outbox") { table in
                table.column("message_id", .text).primaryKey()
                table.column("operation_id", .text)
                    .notNull()
                    .unique()
                    .references("guardian_operations", onDelete: .cascade)
                table.column("target_thread_id", .text).notNull()
                table.column("sealed_payload", .blob).notNull()
                table.column("state", .text).notNull()
                table.column("attempt_count", .integer).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
                table.column("receipt_message_item_id", .text)
                table.column("receipt_turn_id", .text)
                table.column("receipt_accepted_at", .double)
            }
        }
        migrator.registerMigration("guardian-journal-v4-restart-circuit") { database in
            try database.create(table: "guardian_restart_circuits") { table in
                table.column("scope", .text).primaryKey()
                table.column("state_json", .blob).notNull()
                table.column("version", .integer).notNull()
                table.column("updated_at", .double).notNull()
            }
        }
        migrator.registerMigration("guardian-journal-v5-event-evidence") { database in
            try database.alter(table: "guardian_operation_events") { table in
                table.add(column: "actor", .text).notNull().defaults(to: "daemon")
                table.add(column: "reason", .text).notNull().defaults(to: "phase.transition")
                table.add(column: "server_generation", .integer)
                table.add(column: "evidence_id", .text)
            }
            try database.execute(
                sql: """
                UPDATE guardian_operation_events
                SET actor = 'client', reason = 'operation.created'
                WHERE event_index = 0
                """
            )
        }
        migrator.registerMigration("guardian-journal-v6-restart-fence") { database in
            try database.create(table: "guardian_restart_fences") { table in
                table.column("operation_id", .text)
                    .primaryKey()
                    .references("guardian_operations", onDelete: .cascade)
                table.column("bundle_identifier", .text).notNull()
                table.column("bundle_url_path", .text).notNull()
                table.column("signing_identifier", .text).notNull()
                table.column("team_identifier", .text)
                table.column("process_id", .integer).notNull()
                table.column("process_start_identity", .integer).notNull()
                table.column("server_generation", .integer).notNull()
                table.column("captured_at", .double).notNull()
            }
        }
        migrator.registerMigration("guardian-journal-v7-daemon-state") { database in
            try database.create(table: "guardian_daemon_state") { table in
                table.column("singleton_id", .integer).primaryKey()
                table.column("generation", .integer).notNull()
                table.column("last_sequence", .integer).notNull()
                table.column("updated_at", .double).notNull()
                table.check(sql: "singleton_id = 1")
            }
        }
        migrator.registerMigration("guardian-journal-v8-projections") { database in
            try database.create(table: "guardian_task_snapshots") { table in
                table.column("thread_id", .text).primaryKey()
                table.column("state", .text).notNull()
                table.column("source", .text).notNull()
                table.column("server_generation", .integer).notNull()
                table.column("event_sequence", .integer).notNull()
                table.column("confidence", .double).notNull()
                table.column("observed_at", .double).notNull()
                table.column("expires_at", .double).notNull()
                table.column("inventory_completeness", .text).notNull()
                table.check(sql: "server_generation > 0")
                table.check(sql: "event_sequence >= 0")
                table.check(sql: "confidence >= 0 AND confidence <= 1")
                table.check(sql: "expires_at >= observed_at")
            }
            try database.create(table: "guardian_client_sessions") { table in
                table.column("client_id", .text).primaryKey()
                table.column("role", .text).notNull()
                table.column("generation", .integer).notNull()
                table.column("last_acknowledged_sequence", .integer).notNull()
                table.column("updated_at", .double).notNull()
                table.check(sql: "generation > 0")
                table.check(sql: "last_acknowledged_sequence >= 0")
            }
            try database.create(table: "guardian_incidents") { table in
                table.column("id", .text).primaryKey()
                table.column("operation_id", .text)
                table.column("family", .text).notNull()
                table.column("nature", .text).notNull()
                table.column("symptom_code", .text).notNull()
                table.column("changed_variable", .text)
                table.column("evidence_id", .text).notNull()
                table.column("result", .text).notNull()
                table.column("occurred_at", .double).notNull()
            }
        }
        migrator.registerMigration("guardian-journal-v9-projection-checkpoint") { database in
            try database.create(table: "guardian_task_projection_state") { table in
                table.column("singleton_id", .integer).primaryKey()
                table.column("server_generation", .integer).notNull()
                table.column("event_sequence", .integer).notNull()
                table.column("captured_at", .double).notNull()
                table.column("expires_at", .double).notNull()
                table.column("inventory_completeness", .text).notNull()
                table.check(sql: "singleton_id = 1")
                table.check(sql: "server_generation > 0")
                table.check(sql: "event_sequence >= 0")
                table.check(sql: "expires_at >= captured_at")
            }
        }
        migrator.registerMigration("guardian-journal-v10-authority-fence") { database in
            try database.create(table: "guardian_authority_fence") { table in
                table.column("singleton_id", .integer).primaryKey()
                table.column("schema_version", .integer).notNull()
                table.column("phase", .text).notNull()
                table.column("epoch", .integer).notNull()
                table.column("desktop_control_evidence_id", .text)
                table.column("observer_comparison_evidence_id", .text)
                table.column("deployment_id", .text)
                table.column("daemon_generation", .integer)
                table.column("updated_at", .double).notNull()
                table.check(sql: "singleton_id = 1")
                table.check(sql: "schema_version = 1")
                table.check(sql: "epoch >= 0")
                table.check(sql: "daemon_generation IS NULL OR daemon_generation > 0")
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_authority_fence
                    (singleton_id, schema_version, phase, epoch, updated_at)
                VALUES (1, 1, 'legacy_authoritative', 0, 0)
                """
            )
        }
        migrator.registerMigration("guardian-journal-v11-authority-events") { database in
            try database.create(table: "guardian_authority_events") { table in
                table.autoIncrementedPrimaryKey("event_index")
                table.column("from_phase", .text).notNull()
                table.column("to_phase", .text).notNull()
                table.column("epoch", .integer).notNull()
                table.column("desktop_control_evidence_id", .text).notNull()
                table.column("observer_comparison_evidence_id", .text).notNull()
                table.column("deployment_id", .text).notNull()
                table.column("daemon_generation", .integer).notNull()
                table.column("occurred_at", .double).notNull()
                table.check(sql: "epoch >= 0")
                table.check(sql: "daemon_generation > 0")
            }
        }
        migrator.registerMigration("guardian-journal-v12-readiness-manifest") { database in
            try database.create(table: "guardian_operation_capabilities") { table in
                table.column("operation_id", .text)
                    .notNull()
                    .references("guardian_operations", onDelete: .cascade)
                table.column("capability", .text).notNull()
                table.column("requirement", .text).notNull()
                table.column("state", .text).notNull()
                table.column("evidence_id", .text).notNull()
                table.column("observed_at", .double).notNull()
                table.column("deadline", .double).notNull()
                table.primaryKey(["operation_id", "capability"])
                table.check(sql: "length(capability) > 0")
                table.check(sql: "length(evidence_id) > 0")
                table.check(sql: "deadline >= observed_at")
            }
        }
        Self.registerRemoteMigrations(on: &migrator)
        do {
            try migrator.migrate(database)
            try Self.secureStorageFiles(databaseURL: databaseURL)
        } catch {
            throw GuardianJournalError.storageUnavailable
        }
    }

    public func storageJournalMode() throws -> String {
        try database.read { database in
            try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    public func storageSynchronousMode() throws -> Int {
        try database.read { database in
            try Int.fetchOne(database, sql: "PRAGMA synchronous") ?? -1
        }
    }

    public func authorityFence() throws -> GuardianAuthorityFence {
        try database.read { database in
            guard let fence = try Self.fetchAuthorityFence(from: database) else {
                throw GuardianAuthorityFenceError.unprovable
            }
            return fence
        }
    }

    public func authorityEvents() throws -> [GuardianAuthorityEvent] {
        try database.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_authority_events ORDER BY event_index"
            ).map(Self.decodeAuthorityEvent)
        }
    }

    public func replaceReadinessManifest(
        operationID: UUID,
        records: [GuardianCapabilityRecord]
    ) throws {
        let capabilities = records.map(\.capability)
        guard !records.isEmpty,
              Set(capabilities).count == capabilities.count,
              records.allSatisfy(\.isValid) else {
            throw GuardianJournalError.invalidProjectionRecord
        }
        try database.write { database in
            guard try Self.fetchOperation(id: operationID, from: database) != nil else {
                throw GuardianJournalError.operationNotFound(operationID)
            }
            try database.execute(
                sql: "DELETE FROM guardian_operation_capabilities WHERE operation_id = ?",
                arguments: [operationID.uuidString]
            )
            for record in records.sorted(by: { $0.capability < $1.capability }) {
                try database.execute(
                    sql: """
                    INSERT INTO guardian_operation_capabilities
                        (operation_id, capability, requirement, state, evidence_id,
                         observed_at, deadline)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        operationID.uuidString,
                        record.capability,
                        record.requirement.rawValue,
                        record.state.rawValue,
                        record.evidenceID,
                        record.observedAt.timeIntervalSince1970,
                        record.deadline.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    public func readinessManifest(
        operationID: UUID
    ) throws -> [GuardianCapabilityRecord] {
        try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                SELECT * FROM guardian_operation_capabilities
                WHERE operation_id = ?
                ORDER BY capability
                """,
                arguments: [operationID.uuidString]
            ).map(Self.decodeCapabilityRecord)
        }
    }

    public func issueAuthorityPermit(
        owner: GuardianAuthorityOwner,
        at date: Date = Date()
    ) throws -> GuardianAuthorityPermit {
        try database.read { database in
            guard date.timeIntervalSince1970.isFinite,
                  let fence = try Self.fetchAuthorityFence(from: database) else {
                throw GuardianAuthorityFenceError.unprovable
            }
            guard fence.owner == owner else {
                throw GuardianAuthorityFenceError.authorityDenied(owner)
            }
            return GuardianAuthorityPermit(
                owner: owner,
                epoch: fence.epoch,
                issuedAt: date
            )
        }
    }

    public func validateAuthorityPermit(
        _ permit: GuardianAuthorityPermit,
        at date: Date = Date()
    ) throws {
        try database.read { database in
            guard date.timeIntervalSince1970.isFinite,
                  permit.issuedAt.timeIntervalSince1970.isFinite,
                  permit.issuedAt <= date,
                  let fence = try Self.fetchAuthorityFence(from: database) else {
                throw GuardianAuthorityFenceError.unprovable
            }
            guard fence.owner == permit.owner, fence.epoch == permit.epoch else {
                throw GuardianAuthorityFenceError.stalePermit
            }
        }
    }

    @discardableResult
    public func prepareAuthorityCutover(
        proof: GuardianAuthorityCutoverProof,
        lease: GuardianLease,
        at date: Date = Date()
    ) throws -> GuardianAuthorityFence {
        guard proof.isComplete else {
            throw GuardianAuthorityFenceError.invalidCutoverProof
        }
        guard lease.resource == GuardianAuthorityFence.cutoverLeaseResource else {
            throw GuardianAuthorityFenceError.invalidLeaseResource
        }
        return try database.write { database in
            try Self.validate(lease: lease, at: date, in: database)
            let daemonGeneration = try Self.fetchDaemonState(from: database)?.generation ?? 0
            guard daemonGeneration == proof.daemonGeneration else {
                throw GuardianAuthorityFenceError.daemonGenerationMismatch(
                    expected: proof.daemonGeneration,
                    actual: daemonGeneration
                )
            }
            try Self.validateAuthorityCutoverInventory(at: date, in: database)
            try Self.validateNoLegacyOperationsInFlight(in: database)
            guard let current = try Self.fetchAuthorityFence(from: database) else {
                throw GuardianAuthorityFenceError.unprovable
            }
            switch current.phase {
            case .legacyAuthoritative:
                let prepared = GuardianAuthorityFence(
                    phase: .prepared,
                    epoch: current.epoch,
                    proof: proof,
                    updatedAt: date
                )
                try Self.storeAuthorityFence(prepared, in: database)
                faultInjector?(.authorityPreparedBeforeEvent)
                try Self.insertAuthorityEvent(
                    from: current.phase,
                    to: prepared.phase,
                    epoch: prepared.epoch,
                    proof: proof,
                    occurredAt: date,
                    into: database
                )
                return prepared
            case .prepared, .daemonAuthoritative:
                guard current.proof == proof else {
                    throw GuardianAuthorityFenceError.invalidTransition(
                        from: current.phase,
                        to: .prepared
                    )
                }
                return current
            }
        }
    }

    @discardableResult
    public func activateAuthorityCutover(
        expectedEpoch: Int64,
        lease: GuardianLease,
        at date: Date = Date()
    ) throws -> GuardianAuthorityFence {
        guard lease.resource == GuardianAuthorityFence.cutoverLeaseResource else {
            throw GuardianAuthorityFenceError.invalidLeaseResource
        }
        return try database.write { database in
            try Self.validate(lease: lease, at: date, in: database)
            guard let current = try Self.fetchAuthorityFence(from: database) else {
                throw GuardianAuthorityFenceError.unprovable
            }
            if current.phase == .daemonAuthoritative,
               current.epoch == expectedEpoch + 1 {
                return current
            }
            guard current.epoch == expectedEpoch else {
                throw GuardianAuthorityFenceError.staleEpoch(
                    expected: expectedEpoch,
                    actual: current.epoch
                )
            }
            guard current.phase == .prepared,
                  let cutoverProof = current.proof,
                  cutoverProof.isComplete else {
                throw GuardianAuthorityFenceError.invalidTransition(
                    from: current.phase,
                    to: .daemonAuthoritative
                )
            }
            let activated = GuardianAuthorityFence(
                phase: .daemonAuthoritative,
                epoch: current.epoch + 1,
                proof: cutoverProof,
                updatedAt: date
            )
            try Self.storeAuthorityFence(activated, in: database)
            faultInjector?(.authorityActivatedBeforeEvent)
            try Self.insertAuthorityEvent(
                from: current.phase,
                to: activated.phase,
                epoch: activated.epoch,
                proof: cutoverProof,
                occurredAt: date,
                into: database
            )
            return activated
        }
    }

    @discardableResult
    public func beginDaemonGeneration(at date: Date = Date()) throws -> GuardianDaemonState {
        try database.write { database in
            let current = try Self.fetchDaemonState(from: database)
            let next = GuardianDaemonState(
                generation: (current?.generation ?? 0) + 1,
                lastSequence: 0,
                updatedAt: date
            )
            try database.execute(
                sql: """
                INSERT INTO guardian_daemon_state
                    (singleton_id, generation, last_sequence, updated_at)
                VALUES (1, ?, 0, ?)
                ON CONFLICT(singleton_id) DO UPDATE SET
                    generation = excluded.generation,
                    last_sequence = 0,
                    updated_at = excluded.updated_at
                """,
                arguments: [next.generation, date.timeIntervalSince1970]
            )
            return next
        }
    }

    public func nextDaemonEventSequence(
        expectedGeneration: Int64,
        at date: Date = Date()
    ) throws -> Int64 {
        try database.write { database in
            guard let current = try Self.fetchDaemonState(from: database) else {
                throw GuardianJournalError.staleDaemonGeneration(
                    expected: expectedGeneration,
                    current: 0
                )
            }
            guard current.generation == expectedGeneration else {
                throw GuardianJournalError.staleDaemonGeneration(
                    expected: expectedGeneration,
                    current: current.generation
                )
            }
            let next = current.lastSequence + 1
            try database.execute(
                sql: """
                UPDATE guardian_daemon_state
                SET last_sequence = ?, updated_at = ?
                WHERE singleton_id = 1 AND generation = ? AND last_sequence = ?
                """,
                arguments: [
                    next,
                    date.timeIntervalSince1970,
                    expectedGeneration,
                    current.lastSequence,
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.staleDaemonGeneration(
                    expected: expectedGeneration,
                    current: current.generation
                )
            }
            return next
        }
    }

    public func daemonState() throws -> GuardianDaemonState? {
        try database.read { database in
            try Self.fetchDaemonState(from: database)
        }
    }

    public func storeTaskSnapshot(_ snapshot: GuardianStoredTaskSnapshot) throws {
        guard snapshot.isValid else { throw GuardianJournalError.invalidProjectionRecord }
        try database.write { database in
            if let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM guardian_task_snapshots WHERE thread_id = ?",
                arguments: [snapshot.threadID]
            ) {
                let current = try Self.decodeTaskSnapshot(row)
                if current == snapshot { return }
                let isNewer = snapshot.serverGeneration > current.serverGeneration
                    || (snapshot.serverGeneration == current.serverGeneration
                        && snapshot.eventSequence > current.eventSequence)
                guard isNewer else {
                    throw GuardianJournalError.staleTaskSnapshot(snapshot.threadID)
                }
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_task_snapshots
                    (thread_id, state, source, server_generation, event_sequence,
                     confidence, observed_at, expires_at, inventory_completeness)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(thread_id) DO UPDATE SET
                    state = excluded.state,
                    source = excluded.source,
                    server_generation = excluded.server_generation,
                    event_sequence = excluded.event_sequence,
                    confidence = excluded.confidence,
                    observed_at = excluded.observed_at,
                    expires_at = excluded.expires_at,
                    inventory_completeness = excluded.inventory_completeness
                """,
                arguments: [
                    snapshot.threadID,
                    snapshot.state.rawValue,
                    snapshot.source.rawValue,
                    snapshot.serverGeneration,
                    snapshot.eventSequence,
                    snapshot.confidence,
                    snapshot.observedAt.timeIntervalSince1970,
                    snapshot.expiresAt.timeIntervalSince1970,
                    snapshot.inventoryCompleteness.rawValue,
                ]
            )
        }
    }

    public func replaceTaskSnapshots(
        _ snapshots: [GuardianStoredTaskSnapshot],
        serverGeneration: Int64,
        eventSequence: Int64,
        capturedAt: Date,
        expiresAt: Date,
        inventoryCompleteness: TaskInventoryCompleteness
    ) throws {
        let ids = snapshots.map(\.threadID)
        guard serverGeneration > 0,
              eventSequence >= 0,
              capturedAt <= expiresAt,
              inventoryCompleteness == .complete,
              Set(ids).count == ids.count,
              snapshots.allSatisfy({
                  $0.isValid
                      && $0.serverGeneration == serverGeneration
                      && $0.eventSequence == eventSequence
                      && $0.inventoryCompleteness == .complete
              }) else {
            throw GuardianJournalError.invalidProjectionRecord
        }
        try database.write { database in
            let checkpoint = GuardianTaskProjectionCheckpoint(
                serverGeneration: serverGeneration,
                eventSequence: eventSequence,
                capturedAt: capturedAt,
                expiresAt: expiresAt,
                inventoryCompleteness: inventoryCompleteness
            )
            let existingCheckpoint = try Self.fetchTaskProjectionCheckpoint(from: database)
            let existingRows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_task_snapshots ORDER BY thread_id"
            )
            let existing = try existingRows.map(Self.decodeTaskSnapshot)
            if existingCheckpoint == checkpoint,
               existing == snapshots.sorted(by: { $0.threadID < $1.threadID }) {
                return
            }
            guard existingCheckpoint.map({
                serverGeneration > $0.serverGeneration
                    || (serverGeneration == $0.serverGeneration
                        && eventSequence > $0.eventSequence)
            }) ?? true,
            existing.allSatisfy({
                serverGeneration > $0.serverGeneration
                    || (serverGeneration == $0.serverGeneration
                        && eventSequence > $0.eventSequence)
            }) else {
                throw GuardianJournalError.staleTaskSnapshot("complete-inventory")
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_task_projection_state
                    (singleton_id, server_generation, event_sequence, captured_at,
                     expires_at, inventory_completeness)
                VALUES (1, ?, ?, ?, ?, ?)
                ON CONFLICT(singleton_id) DO UPDATE SET
                    server_generation = excluded.server_generation,
                    event_sequence = excluded.event_sequence,
                    captured_at = excluded.captured_at,
                    expires_at = excluded.expires_at,
                    inventory_completeness = excluded.inventory_completeness
                """,
                arguments: [
                    serverGeneration,
                    eventSequence,
                    capturedAt.timeIntervalSince1970,
                    expiresAt.timeIntervalSince1970,
                    inventoryCompleteness.rawValue,
                ]
            )
            try database.execute(sql: "DELETE FROM guardian_task_snapshots")
            for snapshot in snapshots {
                try database.execute(
                    sql: """
                    INSERT INTO guardian_task_snapshots
                        (thread_id, state, source, server_generation, event_sequence,
                         confidence, observed_at, expires_at, inventory_completeness)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        snapshot.threadID,
                        snapshot.state.rawValue,
                        snapshot.source.rawValue,
                        snapshot.serverGeneration,
                        snapshot.eventSequence,
                        snapshot.confidence,
                        snapshot.observedAt.timeIntervalSince1970,
                        snapshot.expiresAt.timeIntervalSince1970,
                        snapshot.inventoryCompleteness.rawValue,
                    ]
                )
            }
        }
    }

    public func taskProjectionCheckpoint() throws -> GuardianTaskProjectionCheckpoint? {
        try database.read { database in
            try Self.fetchTaskProjectionCheckpoint(from: database)
        }
    }

    public func taskSnapshots() throws -> [GuardianStoredTaskSnapshot] {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_task_snapshots ORDER BY thread_id"
            )
            return try rows.map(Self.decodeTaskSnapshot)
        }
    }

    public func storeClientSession(
        _ session: GuardianStoredClientSession,
        expectedCursor: GuardianIPCEventCursor?
    ) throws {
        guard session.isValid else { throw GuardianJournalError.invalidProjectionRecord }
        try database.write { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM guardian_client_sessions WHERE client_id = ?",
                arguments: [session.clientID.uuidString]
            )
            if let row {
                let current = try Self.decodeClientSession(row)
                guard expectedCursor == current.cursor,
                      session.role == current.role,
                      session.updatedAt >= current.updatedAt,
                      session.generation > current.generation
                        || (session.generation == current.generation
                            && session.lastAcknowledgedSequence >= current.lastAcknowledgedSequence)
                else {
                    throw GuardianJournalError.staleClientSession(session.clientID)
                }
            } else if expectedCursor != nil {
                throw GuardianJournalError.staleClientSession(session.clientID)
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_client_sessions
                    (client_id, role, generation, last_acknowledged_sequence, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(client_id) DO UPDATE SET
                    role = excluded.role,
                    generation = excluded.generation,
                    last_acknowledged_sequence = excluded.last_acknowledged_sequence,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    session.clientID.uuidString,
                    session.role.rawValue,
                    session.generation,
                    session.lastAcknowledgedSequence,
                    session.updatedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    public func clientSession(clientID: UUID) throws -> GuardianStoredClientSession? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM guardian_client_sessions WHERE client_id = ?",
                arguments: [clientID.uuidString]
            ) else { return nil }
            return try Self.decodeClientSession(row)
        }
    }

    public func recordIncident(_ incident: GuardianStoredIncident) throws {
        guard incident.isValid else { throw GuardianJournalError.invalidProjectionRecord }
        try database.write { database in
            if let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM guardian_incidents WHERE id = ?",
                arguments: [incident.id.uuidString]
            ) {
                guard try Self.decodeIncident(row) == incident else {
                    throw GuardianJournalError.invalidProjectionRecord
                }
                return
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_incidents
                    (id, operation_id, family, nature, symptom_code, changed_variable,
                     evidence_id, result, occurred_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: StatementArguments([
                    incident.id.uuidString,
                    incident.operationID?.uuidString,
                    incident.family.rawValue,
                    incident.nature.rawValue,
                    incident.symptomCode,
                    incident.changedVariable,
                    incident.evidenceID,
                    incident.result.rawValue,
                    incident.occurredAt.timeIntervalSince1970,
                ] as [(any DatabaseValueConvertible)?])
            )
        }
    }

    public func incidents(limit: Int) throws -> [GuardianStoredIncident] {
        guard limit > 0, limit <= 1_000 else {
            throw GuardianJournalError.invalidProjectionRecord
        }
        return try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_incidents ORDER BY occurred_at DESC, id LIMIT ?",
                arguments: [limit]
            )
            return try rows.map(Self.decodeIncident)
        }
    }

    public func restartCircuit(scope: String) throws -> GuardianStoredRestartCircuit? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT scope, state_json, version, updated_at FROM guardian_restart_circuits WHERE scope = ?",
                arguments: [scope]
            ) else { return nil }
            return try Self.decodeRestartCircuit(row)
        }
    }

    @discardableResult
    public func storeRestartCircuit(
        scope: String,
        state: RestartCircuitState,
        expectedVersion: Int64?,
        at date: Date = Date()
    ) throws -> GuardianStoredRestartCircuit {
        guard !scope.isEmpty else {
            throw GuardianJournalError.staleRestartCircuitVersion(scope)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stateData = try encoder.encode(state)
        return try database.write { database in
            let existingRow = try Row.fetchOne(
                database,
                sql: "SELECT scope, state_json, version, updated_at FROM guardian_restart_circuits WHERE scope = ?",
                arguments: [scope]
            )
            if let existingRow {
                return try Self.updateRestartCircuit(
                    existingRow: existingRow,
                    scope: scope,
                    state: state,
                    stateData: stateData,
                    expectedVersion: expectedVersion,
                    at: date,
                    in: database
                )
            }
            guard expectedVersion == nil else {
                throw GuardianJournalError.staleRestartCircuitVersion(scope)
            }
            let stored = GuardianStoredRestartCircuit(
                scope: scope,
                state: state,
                version: 1,
                updatedAt: date
            )
            try database.execute(
                sql: "INSERT INTO guardian_restart_circuits (scope, state_json, version, updated_at) VALUES (?, ?, ?, ?)",
                arguments: [scope, stateData, stored.version, date.timeIntervalSince1970]
            )
            return stored
        }
    }

    public func create(_ operation: GuardianOperation) throws {
        _ = try createOrGet(operation)
    }

    @discardableResult
    public func createOrGet(_ operation: GuardianOperation) throws -> GuardianOperation {
        guard operation.phase == .prepared else {
            throw GuardianJournalError.invalidInitialPhase(operation.phase)
        }
        guard !operation.originThreadID.isEmpty,
              !operation.originTokenHash.isEmpty,
              operation.updatedAt >= operation.createdAt else {
            throw GuardianJournalError.invalidOriginIdentity
        }
        return try database.write { database in
            if let stored = try Self.fetchOperation(id: operation.id, from: database) {
                guard stored == operation else {
                    throw GuardianJournalError.duplicateOperationConflict(operation.id)
                }
                return stored
            }
            if let stored = try Self.fetchOperation(
                originTokenHash: operation.originTokenHash,
                from: database
            ) {
                guard stored.kind == operation.kind,
                      stored.originThreadID == operation.originThreadID else {
                    throw GuardianJournalError.originTokenConflict
                }
                return stored
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_operations
                    (id, kind, origin_thread_id, origin_token_hash, phase, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    operation.id.uuidString,
                    operation.kind.rawValue,
                    operation.originThreadID,
                    operation.originTokenHash,
                    operation.phase.rawValue,
                    operation.createdAt.timeIntervalSince1970,
                    operation.updatedAt.timeIntervalSince1970,
                ]
            )
            faultInjector?(.operationInsertedBeforeInitialEvent)
            try Self.insertEvent(
                GuardianOperationEvent(
                    operationID: operation.id,
                    index: 0,
                    phase: operation.phase,
                    occurredAt: operation.createdAt,
                    actor: .client,
                    reason: "operation.created"
                ),
                into: database
            )
            return operation
        }
    }

    public func operation(id: UUID) throws -> GuardianOperation? {
        try database.read { database in
            try Self.fetchOperation(id: id, from: database)
        }
    }

    public func operation(originTokenHash: String) throws -> GuardianOperation? {
        guard !originTokenHash.isEmpty else {
            throw GuardianJournalError.invalidOriginIdentity
        }
        return try database.read { database in
            try Self.fetchOperation(
                originTokenHash: originTokenHash,
                from: database
            )
        }
    }

    public func operations() throws -> [GuardianOperation] {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_operations ORDER BY created_at, id"
            )
            return try rows.map(Self.decodeOperation)
        }
    }

    public func scanOperations() throws -> GuardianJournalScan<GuardianOperation> {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_operations ORDER BY created_at, id"
            )
            return Self.scanRows(
                rows,
                table: "guardian_operations",
                primaryKeyColumn: "id",
                decode: Self.decodeOperation
            )
        }
    }

    public func events(operationID: UUID) throws -> [GuardianOperationEvent] {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT operation_id, event_index, phase, occurred_at,
                       actor, reason, server_generation, evidence_id
                FROM guardian_operation_events
                WHERE operation_id = ?
                ORDER BY event_index
                """,
                arguments: [operationID.uuidString]
            )
            return try rows.map(Self.decodeEvent)
        }
    }

    public func enqueueContinuation(_ entry: GuardianOutboxEntry) throws {
        guard entry.messageID == entry.operationID,
              !entry.targetThreadID.isEmpty,
              !entry.sealedPayload.isEmpty,
              entry.state == .pending,
              entry.attemptCount == 0,
              entry.receipt == nil,
              entry.updatedAt >= entry.createdAt else {
            throw GuardianJournalError.invalidOutboxEntry
        }
        try database.write { database in
            guard let operation = try Self.fetchOperation(id: entry.operationID, from: database) else {
                throw GuardianJournalError.operationNotFound(entry.operationID)
            }
            guard operation.kind == .nativeRecovery else {
                throw GuardianJournalError.leaseRequired
            }
            if let stored = try Self.fetchOutboxEntry(messageID: entry.messageID, from: database) {
                guard Self.hasSameDeliveryIdentity(stored, entry) else {
                    throw GuardianJournalError.outboxConflict(entry.messageID)
                }
                return
            }
            guard operation.phase == .targetLoaded else {
                throw GuardianJournalError.invalidTransition(from: operation.phase, to: .continuationSent)
            }
            try Self.insertOutboxEntry(entry, into: database)
            faultInjector?(.outboxInsertedBeforePhaseTransition)
            try Self.applyTransition(
                operation: operation,
                to: .continuationSent,
                at: entry.createdAt,
                context: GuardianTransitionContext(
                    actor: .daemon,
                    reason: "continuation.queued"
                ),
                policy: transitionPolicy,
                faultInjector: faultInjector,
                in: database
            )
        }
    }

    public func outboxEntries(operationID: UUID) throws -> [GuardianOutboxEntry] {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_outbox WHERE operation_id = ? ORDER BY created_at, message_id",
                arguments: [operationID.uuidString]
            )
            return try rows.map(Self.decodeOutboxEntry)
        }
    }

    public func deliverableOutboxEntries() throws -> [GuardianOutboxEntry] {
        try outboxEntries(state: .pending)
    }

    public func outboxEntriesNeedingReconciliation() throws -> [GuardianOutboxEntry] {
        try outboxEntries(state: .awaitingReconciliation)
    }

    public func scanDeliverableOutboxEntries() throws -> GuardianJournalScan<GuardianOutboxEntry> {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_outbox ORDER BY created_at, message_id"
            )
            let scan = Self.scanRows(
                rows,
                table: "guardian_outbox",
                primaryKeyColumn: "message_id",
                decode: Self.decodeOutboxEntry
            )
            return GuardianJournalScan(
                items: scan.items.filter { $0.state == .pending },
                quarantined: scan.quarantined
            )
        }
    }

    @discardableResult
    public func beginOutboxDeliveryAttempt(
        messageID: UUID,
        at date: Date = Date()
    ) throws -> GuardianOutboxEntry {
        try database.write { database in
            guard let entry = try Self.fetchOutboxEntry(messageID: messageID, from: database) else {
                throw GuardianJournalError.outboxNotFound(messageID)
            }
            if entry.state == .awaitingReconciliation { return entry }
            guard entry.state == .pending, date >= entry.updatedAt else {
                throw GuardianJournalError.outboxConflict(messageID)
            }
            let attempt = entry.beginningDeliveryAttempt(at: date)
            try Self.updateOutboxEntry(attempt, in: database)
            return attempt
        }
    }

    public func recordDeliveryReceipt(_ receipt: GuardianDeliveryReceipt) throws {
        guard receipt.messageID == receipt.operationID,
              !receipt.targetThreadID.isEmpty,
              !receipt.messageItemID.isEmpty,
              !receipt.turnID.isEmpty else {
            throw GuardianJournalError.deliveryReceiptMismatch(receipt.messageID)
        }
        try database.write { database in
            guard let entry = try Self.fetchOutboxEntry(messageID: receipt.messageID, from: database) else {
                throw GuardianJournalError.outboxNotFound(receipt.messageID)
            }
            guard entry.operationID == receipt.operationID,
                  entry.targetThreadID == receipt.targetThreadID else {
                throw GuardianJournalError.deliveryReceiptMismatch(receipt.messageID)
            }
            if let storedReceipt = entry.receipt {
                guard storedReceipt == receipt else {
                    throw GuardianJournalError.deliveryReceiptMismatch(receipt.messageID)
                }
                return
            }
            guard entry.state == .awaitingReconciliation,
                  receipt.acceptedAt >= entry.updatedAt else {
                throw GuardianJournalError.deliveryReceiptMismatch(receipt.messageID)
            }
            guard let operation = try Self.fetchOperation(id: receipt.operationID, from: database) else {
                throw GuardianJournalError.operationNotFound(receipt.operationID)
            }
            try Self.updateOutboxEntry(entry.accepting(receipt), in: database)
            faultInjector?(.receiptStoredBeforePhaseTransition)
            try Self.applyTransition(
                operation: operation,
                to: .deliveryReceipt,
                at: receipt.acceptedAt,
                context: GuardianTransitionContext(
                    actor: .codex,
                    reason: "delivery.accepted"
                ),
                policy: transitionPolicy,
                faultInjector: faultInjector,
                in: database
            )
        }
    }

    public func acknowledgeOperation(
        operationID: UUID,
        at date: Date = Date()
    ) throws {
        try database.write { database in
            guard let operation = try Self.fetchOperation(id: operationID, from: database) else {
                throw GuardianJournalError.operationNotFound(operationID)
            }
            guard let entry = try Self.fetchOutboxEntry(messageID: operationID, from: database),
                  entry.state == .accepted,
                  entry.receipt != nil,
                  date >= entry.updatedAt else {
                throw GuardianJournalError.outboxConflict(operationID)
            }
            try Self.updateOutboxEntry(entry.acknowledging(at: date), in: database)
            faultInjector?(.acknowledgementStoredBeforePhaseTransition)
            try Self.applyTransition(
                operation: operation,
                to: .acknowledged,
                at: date,
                context: GuardianTransitionContext(
                    actor: .daemon,
                    reason: "recovery.acknowledged"
                ),
                policy: transitionPolicy,
                faultInjector: faultInjector,
                in: database
            )
        }
        _ = try? database.writeWithoutTransaction { database in
            try database.checkpoint(.truncate)
        }
        try Self.secureStorageFiles(databaseURL: databaseURL)
    }

    private func outboxEntries(state: GuardianOutboxState) throws -> [GuardianOutboxEntry] {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_outbox ORDER BY created_at, message_id"
            )
            return try rows.map(Self.decodeOutboxEntry).filter { $0.state == state }
        }
    }

    public func storeRestartFence(
        operationID: UUID,
        identity: GuardianDesktopProcessIdentity,
        lease: GuardianLease,
        at date: Date = Date()
    ) throws {
        guard (try? GuardianRestartFenceIntegerCodec.validate(identity)) != nil else {
            throw GuardianJournalError.restartIdentityMismatch(operationID)
        }
        return try database.write { database in
            try Self.validate(lease: lease, at: date, in: database)
            guard let operation = try Self.fetchOperation(id: operationID, from: database) else {
                throw GuardianJournalError.operationNotFound(operationID)
            }
            guard operation.kind == .hardRestart, operation.phase == .gated else {
                throw GuardianJournalError.invalidTransition(
                    from: operation.phase,
                    to: .restartIssued
                )
            }
            if let stored = try Self.fetchRestartFence(operationID: operationID, from: database) {
                guard stored == identity else {
                    throw GuardianJournalError.restartFenceConflict(operationID)
                }
                return
            }
            try Self.insertRestartFence(
                operationID: operationID,
                identity: identity,
                capturedAt: date,
                into: database
            )
        }
    }

    public func issueRestart(
        operationID: UUID,
        observedIdentity: GuardianDesktopProcessIdentity,
        lease: GuardianLease,
        at date: Date = Date()
    ) throws -> GuardianRestartIssueDisposition {
        guard (try? GuardianRestartFenceIntegerCodec.validate(observedIdentity)) != nil else {
            throw GuardianJournalError.restartIdentityMismatch(operationID)
        }
        return try database.write { database in
            try Self.validate(lease: lease, at: date, in: database)
            guard let storedIdentity = try Self.fetchRestartFence(
                operationID: operationID,
                from: database
            ), storedIdentity == observedIdentity else {
                throw GuardianJournalError.restartIdentityMismatch(operationID)
            }
            guard let operation = try Self.fetchOperation(id: operationID, from: database) else {
                throw GuardianJournalError.operationNotFound(operationID)
            }
            if operation.phase == .restartIssued {
                return .resumePreviouslyIssued
            }
            guard operation.phase == .gated else {
                throw GuardianJournalError.invalidTransition(
                    from: operation.phase,
                    to: .restartIssued
                )
            }
            try Self.applyTransition(
                operation: operation,
                to: .restartIssued,
                at: date,
                context: GuardianTransitionContext(
                    actor: .daemon,
                    reason: "desktop.restart-issued",
                    serverGeneration: observedIdentity.serverGeneration,
                    evidenceID: "process-start:\(observedIdentity.processStartIdentity)"
                ),
                policy: transitionPolicy,
                faultInjector: faultInjector,
                in: database
            )
            return .newlyIssued
        }
    }

    public func acquireLease(
        resource: String,
        ownerID: UUID,
        now: Date = Date(),
        duration: TimeInterval
    ) throws -> GuardianLease {
        guard !resource.isEmpty, duration > 0 else {
            throw GuardianJournalError.invalidLeaseDuration
        }
        return try database.write { database in
            if let existing = try Self.fetchLease(resource: resource, from: database) {
                if existing.expiresAt > now {
                    guard existing.ownerID == ownerID else {
                        throw GuardianJournalError.leaseBusy(resource)
                    }
                    return existing
                }
                let replacement = GuardianLease(
                    resource: resource,
                    ownerID: ownerID,
                    generation: existing.generation + 1,
                    expiresAt: now.addingTimeInterval(duration)
                )
                try Self.storeLease(replacement, at: now, in: database)
                return replacement
            }
            let lease = GuardianLease(
                resource: resource,
                ownerID: ownerID,
                generation: 1,
                expiresAt: now.addingTimeInterval(duration)
            )
            try Self.storeLease(lease, at: now, in: database)
            return lease
        }
    }

    public func renewLease(
        _ lease: GuardianLease,
        now: Date = Date(),
        duration: TimeInterval
    ) throws -> GuardianLease {
        guard duration > 0 else {
            throw GuardianJournalError.invalidLeaseDuration
        }
        return try database.write { database in
            guard let current = try Self.fetchLease(resource: lease.resource, from: database),
                  current == lease,
                  current.expiresAt > now else {
                throw GuardianJournalError.staleLease(lease.resource)
            }
            let renewed = GuardianLease(
                resource: lease.resource,
                ownerID: lease.ownerID,
                generation: lease.generation + 1,
                expiresAt: now.addingTimeInterval(duration)
            )
            guard renewed.expiresAt > current.expiresAt else {
                throw GuardianJournalError.invalidLeaseDuration
            }
            try Self.storeLease(renewed, at: now, in: database)
            return renewed
        }
    }

    public func releaseLease(
        _ lease: GuardianLease,
        at date: Date = Date()
    ) throws {
        try database.write { database in
            guard let current = try Self.fetchLease(resource: lease.resource, from: database),
                  current == lease,
                  current.expiresAt > date else {
                throw GuardianJournalError.staleLease(lease.resource)
            }
            let released = GuardianLease(
                resource: lease.resource,
                ownerID: lease.ownerID,
                generation: lease.generation,
                expiresAt: date
            )
            try Self.storeLease(released, at: date, in: database)
        }
    }

    public func transition(
        operationID: UUID,
        to phase: GuardianOperationPhase,
        context: GuardianTransitionContext = .phaseTransition,
        at date: Date = Date()
    ) throws {
        try database.write { database in
            guard let operation = try Self.fetchOperation(id: operationID, from: database) else {
                throw GuardianJournalError.operationNotFound(operationID)
            }
            guard operation.kind == .nativeRecovery else {
                throw GuardianJournalError.leaseRequired
            }
            try Self.applyTransition(
                operation: operation,
                to: phase,
                at: date,
                context: context,
                policy: transitionPolicy,
                faultInjector: faultInjector,
                in: database
            )
        }
    }

    public func transition(
        operationID: UUID,
        expectedPhase: GuardianOperationPhase,
        to phase: GuardianOperationPhase,
        lease: GuardianLease,
        context: GuardianTransitionContext = .phaseTransition,
        at date: Date = Date()
    ) throws {
        try database.write { database in
            guard let currentLease = try Self.fetchLease(resource: lease.resource, from: database),
                  currentLease == lease,
                  currentLease.expiresAt > date else {
                throw GuardianJournalError.staleLease(lease.resource)
            }
            guard let operation = try Self.fetchOperation(id: operationID, from: database) else {
                throw GuardianJournalError.operationNotFound(operationID)
            }
            guard operation.phase == expectedPhase else {
                throw GuardianJournalError.invalidTransition(
                    from: operation.phase,
                    to: phase
                )
            }
            try Self.applyTransition(
                operation: operation,
                to: phase,
                at: date,
                context: context,
                policy: transitionPolicy,
                faultInjector: faultInjector,
                in: database
            )
        }
    }

    private static func fetchOperation(
        id: UUID,
        from database: Database
    ) throws -> GuardianOperation? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_operations WHERE id = ?",
            arguments: [id.uuidString]
        ) else { return nil }
        return try decodeOperation(row)
    }

    private static func fetchAuthorityFence(
        from database: Database
    ) throws -> GuardianAuthorityFence? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_authority_fence WHERE singleton_id = 1"
        ) else { return nil }
        let schemaVersion: Int = row["schema_version"]
        let phaseText: String = row["phase"]
        let epoch: Int64 = row["epoch"]
        let desktopEvidence: String? = row["desktop_control_evidence_id"]
        let comparisonEvidence: String? = row["observer_comparison_evidence_id"]
        let deploymentID: String? = row["deployment_id"]
        let daemonGeneration: Int64? = row["daemon_generation"]
        let updatedAtValue: Double = row["updated_at"]
        guard schemaVersion == GuardianAuthorityFence.schemaVersion,
              let phase = GuardianAuthorityPhase(rawValue: phaseText) else {
            throw GuardianAuthorityFenceError.unprovable
        }
        let proof: GuardianAuthorityCutoverProof?
        switch (desktopEvidence, comparisonEvidence, deploymentID, daemonGeneration) {
        case let (.some(desktop), .some(comparison), .some(deployment), .some(generation)):
            proof = GuardianAuthorityCutoverProof(
                desktopControlEvidenceID: desktop,
                observerComparisonEvidenceID: comparison,
                deploymentID: deployment,
                daemonGeneration: generation
            )
        case (nil, nil, nil, nil):
            proof = nil
        default:
            throw GuardianAuthorityFenceError.unprovable
        }
        let fence = GuardianAuthorityFence(
            phase: phase,
            epoch: epoch,
            proof: proof,
            updatedAt: Date(timeIntervalSince1970: updatedAtValue)
        )
        guard fence.isValid else {
            throw GuardianAuthorityFenceError.unprovable
        }
        return fence
    }

    private static func storeAuthorityFence(
        _ fence: GuardianAuthorityFence,
        in database: Database
    ) throws {
        guard fence.isValid else {
            throw GuardianAuthorityFenceError.unprovable
        }
        try database.execute(
            sql: """
            UPDATE guardian_authority_fence SET
                schema_version = ?, phase = ?, epoch = ?,
                desktop_control_evidence_id = ?, observer_comparison_evidence_id = ?,
                deployment_id = ?, daemon_generation = ?, updated_at = ?
            WHERE singleton_id = 1
            """,
            arguments: StatementArguments([
                GuardianAuthorityFence.schemaVersion,
                fence.phase.rawValue,
                fence.epoch,
                fence.proof?.desktopControlEvidenceID,
                fence.proof?.observerComparisonEvidenceID,
                fence.proof?.deploymentID,
                fence.proof?.daemonGeneration,
                fence.updatedAt.timeIntervalSince1970,
            ] as [(any DatabaseValueConvertible)?])
        )
        guard database.changesCount == 1 else {
            throw GuardianAuthorityFenceError.unprovable
        }
    }

    private static func decodeAuthorityEvent(_ row: Row) throws -> GuardianAuthorityEvent {
        let index: Int64 = row["event_index"]
        let fromText: String = row["from_phase"]
        let toText: String = row["to_phase"]
        let epoch: Int64 = row["epoch"]
        let occurredAtValue: Double = row["occurred_at"]
        guard index > 0,
              let from = GuardianAuthorityPhase(rawValue: fromText),
              let to = GuardianAuthorityPhase(rawValue: toText),
              epoch >= 0,
              occurredAtValue.isFinite else {
            throw GuardianAuthorityFenceError.unprovable
        }
        let proof = GuardianAuthorityCutoverProof(
            desktopControlEvidenceID: row["desktop_control_evidence_id"],
            observerComparisonEvidenceID: row["observer_comparison_evidence_id"],
            deploymentID: row["deployment_id"],
            daemonGeneration: row["daemon_generation"]
        )
        guard proof.isComplete else {
            throw GuardianAuthorityFenceError.unprovable
        }
        return GuardianAuthorityEvent(
            index: index,
            from: from,
            to: to,
            epoch: epoch,
            proof: proof,
            occurredAt: Date(timeIntervalSince1970: occurredAtValue)
        )
    }

    private static func decodeCapabilityRecord(_ row: Row) throws -> GuardianCapabilityRecord {
        let requirementText: String = row["requirement"]
        let stateText: String = row["state"]
        let observedAtValue: Double = row["observed_at"]
        let deadlineValue: Double = row["deadline"]
        guard let requirement = GuardianCapabilityRequirement(rawValue: requirementText),
              let state = GuardianCapabilityState(rawValue: stateText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let record = GuardianCapabilityRecord(
            capability: row["capability"],
            requirement: requirement,
            state: state,
            evidenceID: row["evidence_id"],
            observedAt: Date(timeIntervalSince1970: observedAtValue),
            deadline: Date(timeIntervalSince1970: deadlineValue)
        )
        guard record.isValid else {
            throw GuardianJournalError.corruptStoredOperation
        }
        return record
    }

    private static func insertAuthorityEvent(
        from: GuardianAuthorityPhase,
        to: GuardianAuthorityPhase,
        epoch: Int64,
        proof: GuardianAuthorityCutoverProof,
        occurredAt: Date,
        into database: Database
    ) throws {
        guard proof.isComplete,
              epoch >= 0,
              occurredAt.timeIntervalSince1970.isFinite else {
            throw GuardianAuthorityFenceError.unprovable
        }
        try database.execute(
            sql: """
            INSERT INTO guardian_authority_events
                (from_phase, to_phase, epoch, desktop_control_evidence_id,
                 observer_comparison_evidence_id, deployment_id, daemon_generation,
                 occurred_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                from.rawValue,
                to.rawValue,
                epoch,
                proof.desktopControlEvidenceID,
                proof.observerComparisonEvidenceID,
                proof.deploymentID,
                proof.daemonGeneration,
                occurredAt.timeIntervalSince1970,
            ]
        )
    }

    private static func fetchDaemonState(from database: Database) throws -> GuardianDaemonState? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT generation, last_sequence, updated_at FROM guardian_daemon_state WHERE singleton_id = 1"
        ) else { return nil }
        let generation: Int64 = row["generation"]
        let lastSequence: Int64 = row["last_sequence"]
        let updatedAt: Double = row["updated_at"]
        guard generation > 0, lastSequence >= 0 else {
            throw GuardianJournalError.corruptStoredOperation
        }
        return GuardianDaemonState(
            generation: generation,
            lastSequence: lastSequence,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private static func fetchTaskProjectionCheckpoint(
        from database: Database
    ) throws -> GuardianTaskProjectionCheckpoint? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_task_projection_state WHERE singleton_id = 1"
        ) else { return nil }
        let generation: Int64 = row["server_generation"]
        let sequence: Int64 = row["event_sequence"]
        let capturedAtValue: Double = row["captured_at"]
        let expiresAtValue: Double = row["expires_at"]
        let completenessText: String = row["inventory_completeness"]
        guard let completeness = TaskInventoryCompleteness(rawValue: completenessText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let checkpoint = GuardianTaskProjectionCheckpoint(
            serverGeneration: generation,
            eventSequence: sequence,
            capturedAt: Date(timeIntervalSince1970: capturedAtValue),
            expiresAt: Date(timeIntervalSince1970: expiresAtValue),
            inventoryCompleteness: completeness
        )
        guard checkpoint.isValid else {
            throw GuardianJournalError.corruptStoredOperation
        }
        return checkpoint
    }

    private static func validateAuthorityCutoverInventory(
        at date: Date,
        in database: Database
    ) throws {
        guard date.timeIntervalSince1970.isFinite,
              let checkpoint = try fetchTaskProjectionCheckpoint(from: database),
              checkpoint.inventoryCompleteness == .complete,
              checkpoint.capturedAt <= date,
              checkpoint.expiresAt > date else {
            throw GuardianAuthorityFenceError.inventoryNotAuthoritative
        }
        let snapshots = try Row.fetchAll(
            database,
            sql: "SELECT * FROM guardian_task_snapshots ORDER BY thread_id"
        ).map(decodeTaskSnapshot)
        guard snapshots.allSatisfy({ snapshot in
            snapshot.inventoryCompleteness == .complete
                && snapshot.serverGeneration == checkpoint.serverGeneration
                && snapshot.eventSequence == checkpoint.eventSequence
                && snapshot.expiresAt > date
                && snapshot.state != .unknown
        }) else {
            throw GuardianAuthorityFenceError.inventoryNotAuthoritative
        }
    }

    private static func validateNoLegacyOperationsInFlight(
        in database: Database
    ) throws {
        let terminal: Set<GuardianOperationPhase> = [.acknowledged, .deadLetter]
        let operations = try Row.fetchAll(
            database,
            sql: "SELECT * FROM guardian_operations ORDER BY created_at, id"
        ).map(decodeOperation)
        if let operation = operations.first(where: { !terminal.contains($0.phase) }) {
            throw GuardianAuthorityFenceError.legacyOperationInFlight(operation.id)
        }
    }

    private static func validate(
        lease: GuardianLease,
        at date: Date,
        in database: Database
    ) throws {
        guard let current = try fetchLease(resource: lease.resource, from: database),
              current == lease,
              current.expiresAt > date else {
            throw GuardianJournalError.staleLease(lease.resource)
        }
    }

    private static func fetchRestartFence(
        operationID: UUID,
        from database: Database
    ) throws -> GuardianDesktopProcessIdentity? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_restart_fences WHERE operation_id = ?",
            arguments: [operationID.uuidString]
        ) else { return nil }
        let processID: Int64 = row["process_id"]
        let processStartIdentity: Int64 = row["process_start_identity"]
        let serverGeneration: Int64 = row["server_generation"]
        let identity = GuardianDesktopProcessIdentity(
            bundleIdentifier: row["bundle_identifier"],
            bundleURLPath: row["bundle_url_path"],
            signingIdentifier: row["signing_identifier"],
            teamIdentifier: row["team_identifier"],
            processID: try GuardianRestartFenceIntegerCodec.decodeProcessID(processID),
            processStartIdentity: try GuardianRestartFenceIntegerCodec.decodeProcessStartIdentity(
                processStartIdentity
            ),
            serverGeneration: serverGeneration
        )
        try GuardianRestartFenceIntegerCodec.validate(identity)
        return identity
    }

    private static func insertRestartFence(
        operationID: UUID,
        identity: GuardianDesktopProcessIdentity,
        capturedAt: Date,
        into database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO guardian_restart_fences
                (operation_id, bundle_identifier, bundle_url_path, signing_identifier,
                 team_identifier, process_id, process_start_identity, server_generation,
                 captured_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: StatementArguments([
                operationID.uuidString,
                identity.bundleIdentifier,
                identity.bundleURLPath,
                identity.signingIdentifier,
                identity.teamIdentifier,
                Int64(identity.processID),
                try GuardianRestartFenceIntegerCodec.encodeProcessStartIdentity(
                    identity.processStartIdentity
                ),
                identity.serverGeneration,
                capturedAt.timeIntervalSince1970,
            ] as [(any DatabaseValueConvertible)?])
        )
    }

    private static func decodeTaskSnapshot(_ row: Row) throws -> GuardianStoredTaskSnapshot {
        let stateText: String = row["state"]
        let sourceText: String = row["source"]
        let inventoryText: String = row["inventory_completeness"]
        guard let state = AuthoritativeTaskState(rawValue: stateText),
              let source = TaskEvidenceSource(rawValue: sourceText),
              let inventory = TaskInventoryCompleteness(rawValue: inventoryText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let observedAt: Double = row["observed_at"]
        let expiresAt: Double = row["expires_at"]
        let snapshot = GuardianStoredTaskSnapshot(
            threadID: row["thread_id"],
            state: state,
            source: source,
            serverGeneration: row["server_generation"],
            eventSequence: row["event_sequence"],
            confidence: row["confidence"],
            observedAt: Date(timeIntervalSince1970: observedAt),
            expiresAt: Date(timeIntervalSince1970: expiresAt),
            inventoryCompleteness: inventory
        )
        guard snapshot.isValid else { throw GuardianJournalError.corruptStoredOperation }
        return snapshot
    }

    private static func decodeClientSession(_ row: Row) throws -> GuardianStoredClientSession {
        let clientText: String = row["client_id"]
        let roleText: String = row["role"]
        guard let clientID = UUID(uuidString: clientText),
              let role = GuardianIPCClientRole(rawValue: roleText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let updatedAt: Double = row["updated_at"]
        let session = GuardianStoredClientSession(
            clientID: clientID,
            role: role,
            generation: row["generation"],
            lastAcknowledgedSequence: row["last_acknowledged_sequence"],
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
        guard session.isValid else { throw GuardianJournalError.corruptStoredOperation }
        return session
    }

    private static func decodeIncident(_ row: Row) throws -> GuardianStoredIncident {
        let idText: String = row["id"]
        let operationText: String? = row["operation_id"]
        let familyText: String = row["family"]
        let natureText: String = row["nature"]
        let resultText: String = row["result"]
        guard let id = UUID(uuidString: idText),
              let family = RepairFailureFamily(rawValue: familyText),
              let nature = RepairFailureNature(rawValue: natureText),
              let result = RepairAttemptResult(rawValue: resultText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let operationID: UUID?
        if let operationText {
            guard let parsed = UUID(uuidString: operationText) else {
                throw GuardianJournalError.corruptStoredOperation
            }
            operationID = parsed
        } else {
            operationID = nil
        }
        let occurredAt: Double = row["occurred_at"]
        let incident = GuardianStoredIncident(
            id: id,
            operationID: operationID,
            family: family,
            nature: nature,
            symptomCode: row["symptom_code"],
            changedVariable: row["changed_variable"],
            evidenceID: row["evidence_id"],
            result: result,
            occurredAt: Date(timeIntervalSince1970: occurredAt)
        )
        guard incident.isValid else { throw GuardianJournalError.corruptStoredOperation }
        return incident
    }

    private static func decodeRestartCircuit(_ row: Row) throws -> GuardianStoredRestartCircuit {
        let scope: String = row["scope"]
        let stateData: Data = row["state_json"]
        let version: Int64 = row["version"]
        let updatedAtValue: Double = row["updated_at"]
        guard !scope.isEmpty, version > 0,
              let state = try? JSONDecoder().decode(RestartCircuitState.self, from: stateData) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        return GuardianStoredRestartCircuit(
            scope: scope,
            state: state,
            version: version,
            updatedAt: Date(timeIntervalSince1970: updatedAtValue)
        )
    }

    private static func updateRestartCircuit(
        existingRow: Row,
        scope: String,
        state: RestartCircuitState,
        stateData: Data,
        expectedVersion: Int64?,
        at date: Date,
        in database: Database
    ) throws -> GuardianStoredRestartCircuit {
        let existing = try decodeRestartCircuit(existingRow)
        if expectedVersion == nil, existing.state == state {
            return existing
        }
        guard expectedVersion == existing.version, date >= existing.updatedAt else {
            throw GuardianJournalError.staleRestartCircuitVersion(scope)
        }
        let updated = GuardianStoredRestartCircuit(
            scope: scope,
            state: state,
            version: existing.version + 1,
            updatedAt: date
        )
        try database.execute(
            sql: """
            UPDATE guardian_restart_circuits
            SET state_json = ?, version = ?, updated_at = ?
            WHERE scope = ? AND version = ?
            """,
            arguments: [
                stateData,
                updated.version,
                date.timeIntervalSince1970,
                scope,
                existing.version,
            ]
        )
        guard database.changesCount == 1 else {
            throw GuardianJournalError.staleRestartCircuitVersion(scope)
        }
        return updated
    }

    private static func fetchOperation(
        originTokenHash: String,
        from database: Database
    ) throws -> GuardianOperation? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_operations WHERE origin_token_hash = ?",
            arguments: [originTokenHash]
        ) else { return nil }
        return try decodeOperation(row)
    }

    private static func fetchLease(
        resource: String,
        from database: Database
    ) throws -> GuardianLease? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT resource, owner_id, generation, expires_at FROM guardian_leases WHERE resource = ?",
            arguments: [resource]
        ) else { return nil }
        let ownerText: String = row["owner_id"]
        guard let ownerID = UUID(uuidString: ownerText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let storedResource: String = row["resource"]
        let generation: Int64 = row["generation"]
        let expiresAt: Double = row["expires_at"]
        guard !storedResource.isEmpty, generation > 0 else {
            throw GuardianJournalError.corruptStoredOperation
        }
        return GuardianLease(
            resource: storedResource,
            ownerID: ownerID,
            generation: generation,
            expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
    }

    private static func storeLease(
        _ lease: GuardianLease,
        at date: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO guardian_leases (resource, owner_id, generation, expires_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(resource) DO UPDATE SET
                owner_id = excluded.owner_id,
                generation = excluded.generation,
                expires_at = excluded.expires_at,
                updated_at = excluded.updated_at
            """,
            arguments: [
                lease.resource,
                lease.ownerID.uuidString,
                lease.generation,
                lease.expiresAt.timeIntervalSince1970,
                date.timeIntervalSince1970,
            ]
        )
    }

    private static func applyTransition(
        operation: GuardianOperation,
        to phase: GuardianOperationPhase,
        at date: Date,
        context: GuardianTransitionContext,
        policy: GuardianOperationTransitionPolicy,
        faultInjector: GuardianJournalFaultInjector?,
        in database: Database
    ) throws {
        if operation.phase == phase { return }
        guard date >= operation.updatedAt,
              policy.allows(
                kind: operation.kind,
                from: operation.phase,
                to: phase
              ) else {
            throw GuardianJournalError.invalidTransition(from: operation.phase, to: phase)
        }

        let updated = operation.advancing(to: phase, at: date)
        try database.execute(
            sql: "UPDATE guardian_operations SET phase = ?, updated_at = ? WHERE id = ?",
            arguments: [
                updated.phase.rawValue,
                updated.updatedAt.timeIntervalSince1970,
                updated.id.uuidString,
            ]
        )
        faultInjector?(.operationPhaseUpdatedBeforeEvent(phase))
        let nextIndex = try Int.fetchOne(
            database,
            sql: """
            SELECT COALESCE(MAX(event_index), -1) + 1
            FROM guardian_operation_events
            WHERE operation_id = ?
            """,
            arguments: [operation.id.uuidString]
        ) ?? 0
        try insertEvent(
            GuardianOperationEvent(
                operationID: operation.id,
                index: nextIndex,
                phase: phase,
                occurredAt: date,
                actor: context.actor,
                reason: context.reason,
                serverGeneration: context.serverGeneration,
                evidenceID: context.evidenceID
            ),
            into: database
        )
    }

    private static func fetchOutboxEntry(
        messageID: UUID,
        from database: Database
    ) throws -> GuardianOutboxEntry? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_outbox WHERE message_id = ?",
            arguments: [messageID.uuidString]
        ) else { return nil }
        return try decodeOutboxEntry(row)
    }

    private static func decodeOutboxEntry(_ row: Row) throws -> GuardianOutboxEntry {
        let operationText: String = row["operation_id"]
        let messageText: String = row["message_id"]
        let stateText: String = row["state"]
        guard let operationID = UUID(uuidString: operationText),
              let messageID = UUID(uuidString: messageText),
              let state = GuardianOutboxState(rawValue: stateText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let targetThreadID: String = row["target_thread_id"]
        let sealedPayload: Data = row["sealed_payload"]
        let attemptCount: Int = row["attempt_count"]
        let createdAtValue: Double = row["created_at"]
        let updatedAtValue: Double = row["updated_at"]
        let itemID: String? = row["receipt_message_item_id"]
        let turnID: String? = row["receipt_turn_id"]
        let acceptedAtValue: Double? = row["receipt_accepted_at"]
        let receipt: GuardianDeliveryReceipt?
        switch (itemID, turnID, acceptedAtValue) {
        case let (.some(itemID), .some(turnID), .some(acceptedAtValue)):
            receipt = GuardianDeliveryReceipt(
                operationID: operationID,
                messageID: messageID,
                targetThreadID: targetThreadID,
                messageItemID: itemID,
                turnID: turnID,
                acceptedAt: Date(timeIntervalSince1970: acceptedAtValue)
            )
        case (nil, nil, nil):
            receipt = nil
        default:
            throw GuardianJournalError.corruptStoredOperation
        }
        let entry = GuardianOutboxEntry(
            operationID: operationID,
            messageID: messageID,
            targetThreadID: targetThreadID,
            sealedPayload: sealedPayload,
            state: state,
            attemptCount: attemptCount,
            createdAt: Date(timeIntervalSince1970: createdAtValue),
            updatedAt: Date(timeIntervalSince1970: updatedAtValue),
            receipt: receipt
        )
        guard messageID == operationID,
              !targetThreadID.isEmpty,
              attemptCount >= 0,
              createdAtValue.isFinite,
              updatedAtValue.isFinite,
              updatedAtValue >= createdAtValue else {
            throw GuardianJournalError.corruptStoredOperation
        }
        switch state {
        case .pending:
            guard attemptCount == 0, !sealedPayload.isEmpty, receipt == nil else {
                throw GuardianJournalError.corruptStoredOperation
            }
        case .awaitingReconciliation:
            guard attemptCount > 0, !sealedPayload.isEmpty, receipt == nil else {
                throw GuardianJournalError.corruptStoredOperation
            }
        case .accepted:
            guard attemptCount > 0, !sealedPayload.isEmpty, receipt != nil else {
                throw GuardianJournalError.corruptStoredOperation
            }
        case .acknowledged:
            guard attemptCount > 0, sealedPayload.isEmpty, receipt != nil else {
                throw GuardianJournalError.corruptStoredOperation
            }
        case .deadLetter:
            break
        }
        if let receipt {
            guard receipt.operationID == operationID,
                  receipt.messageID == messageID,
                  receipt.targetThreadID == targetThreadID,
                  !receipt.messageItemID.isEmpty,
                  !receipt.turnID.isEmpty,
                  receipt.acceptedAt.timeIntervalSince1970.isFinite else {
                throw GuardianJournalError.corruptStoredOperation
            }
        }
        return entry
    }

    private static func scanRows<Item: Sendable>(
        _ rows: [Row],
        table: String,
        primaryKeyColumn: String,
        decode: (Row) throws -> Item
    ) -> GuardianJournalScan<Item> {
        var items: [Item] = []
        var quarantined: [GuardianQuarantinedRow] = []
        for (index, row) in rows.enumerated() {
            do {
                items.append(try decode(row))
            } catch {
                let value: DatabaseValue = row[primaryKeyColumn]
                let primaryKey = String.fromDatabaseValue(value) ?? "invalid-row-\(index)"
                quarantined.append(GuardianQuarantinedRow(
                    table: table,
                    primaryKey: primaryKey,
                    reason: .invalidRecord
                ))
            }
        }
        return GuardianJournalScan(items: items, quarantined: quarantined)
    }

    private static func hasSameDeliveryIdentity(
        _ lhs: GuardianOutboxEntry,
        _ rhs: GuardianOutboxEntry
    ) -> Bool {
        lhs.operationID == rhs.operationID
            && lhs.messageID == rhs.messageID
            && lhs.targetThreadID == rhs.targetThreadID
            && lhs.sealedPayload == rhs.sealedPayload
    }

    private static func insertOutboxEntry(
        _ entry: GuardianOutboxEntry,
        into database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO guardian_outbox
                (message_id, operation_id, target_thread_id, sealed_payload, state,
                 attempt_count, created_at, updated_at, receipt_message_item_id,
                 receipt_turn_id, receipt_accepted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: StatementArguments([
                entry.messageID.uuidString,
                entry.operationID.uuidString,
                entry.targetThreadID,
                entry.sealedPayload,
                entry.state.rawValue,
                entry.attemptCount,
                entry.createdAt.timeIntervalSince1970,
                entry.updatedAt.timeIntervalSince1970,
                entry.receipt?.messageItemID,
                entry.receipt?.turnID,
                entry.receipt?.acceptedAt.timeIntervalSince1970,
            ] as [(any DatabaseValueConvertible)?])
        )
    }

    private static func updateOutboxEntry(
        _ entry: GuardianOutboxEntry,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE guardian_outbox SET
                sealed_payload = ?, state = ?, attempt_count = ?, updated_at = ?,
                receipt_message_item_id = ?, receipt_turn_id = ?, receipt_accepted_at = ?
            WHERE message_id = ?
            """,
            arguments: StatementArguments([
                entry.sealedPayload,
                entry.state.rawValue,
                entry.attemptCount,
                entry.updatedAt.timeIntervalSince1970,
                entry.receipt?.messageItemID,
                entry.receipt?.turnID,
                entry.receipt?.acceptedAt.timeIntervalSince1970,
                entry.messageID.uuidString,
            ] as [(any DatabaseValueConvertible)?])
        )
    }

    private static func decodeOperation(_ row: Row) throws -> GuardianOperation {
        let idText: String = row["id"]
        let kindText: String = row["kind"]
        let phaseText: String = row["phase"]
        guard let id = UUID(uuidString: idText),
              let kind = GuardianOperationKind(rawValue: kindText),
              let phase = GuardianOperationPhase(rawValue: phaseText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let originThreadID: String = row["origin_thread_id"]
        let originTokenHash: String = row["origin_token_hash"]
        let createdAt: Double = row["created_at"]
        let updatedAt: Double = row["updated_at"]
        return GuardianOperation(
            id: id,
            kind: kind,
            originThreadID: originThreadID,
            originTokenHash: originTokenHash,
            phase: phase,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private static func decodeEvent(_ row: Row) throws -> GuardianOperationEvent {
        let idText: String = row["operation_id"]
        let phaseText: String = row["phase"]
        let actorText: String = row["actor"]
        guard let id = UUID(uuidString: idText),
              let phase = GuardianOperationPhase(rawValue: phaseText),
              let actor = GuardianEventActor(rawValue: actorText) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        let index: Int = row["event_index"]
        let occurredAt: Double = row["occurred_at"]
        let reason: String = row["reason"]
        let serverGeneration: Int64? = row["server_generation"]
        let evidenceID: String? = row["evidence_id"]
        return GuardianOperationEvent(
            operationID: id,
            index: index,
            phase: phase,
            occurredAt: Date(timeIntervalSince1970: occurredAt),
            actor: actor,
            reason: reason,
            serverGeneration: serverGeneration,
            evidenceID: evidenceID
        )
    }

    private static func insertEvent(
        _ event: GuardianOperationEvent,
        into database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO guardian_operation_events
                (operation_id, event_index, phase, occurred_at, actor, reason,
                 server_generation, evidence_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: StatementArguments([
                event.operationID.uuidString,
                event.index,
                event.phase.rawValue,
                event.occurredAt.timeIntervalSince1970,
                event.actor.rawValue,
                event.reason,
                event.serverGeneration,
                event.evidenceID,
            ] as [(any DatabaseValueConvertible)?])
        )
    }

    private static func secureStorageFiles(databaseURL: URL) throws {
        let fileManager = FileManager.default
        for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        where fileManager.fileExists(atPath: path) {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }
}
