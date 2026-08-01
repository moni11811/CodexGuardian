import CryptoKit
import Foundation
import GRDB

extension GuardianJournal {
    static func registerRemoteMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("guardian-journal-v13-remote-trust") { database in
            try database.create(table: "guardian_remote_devices") { table in
                table.column("device_id", .text).primaryKey()
                table.column("public_key", .blob).notNull().unique()
                table.column("capabilities", .integer).notNull()
                table.column("status", .text).notNull()
                table.column("pairing_epoch", .integer).notNull()
                table.column("revocation_epoch", .integer).notNull()
                table.column("last_accepted_sequence", .integer).notNull()
                table.column("paired_at", .double).notNull()
                table.column("last_seen_at", .double)
                table.check(sql: "length(public_key) = 32")
                table.check(sql: "capabilities > 0")
                table.check(sql: "pairing_epoch > 0")
                table.check(sql: "revocation_epoch >= 0")
                table.check(sql: "last_accepted_sequence >= 0")
            }
            try database.create(table: "guardian_pairing_challenges") { table in
                table.column("nonce_hash", .blob).primaryKey()
                table.column("guardian_identity_hash", .blob).notNull()
                table.column("issued_at", .double).notNull()
                table.column("expires_at", .double).notNull()
                table.column("consumed_at", .double)
                table.check(sql: "length(nonce_hash) = 32")
                table.check(sql: "length(guardian_identity_hash) = 32")
                table.check(sql: "expires_at > issued_at")
                table.check(sql: "consumed_at IS NULL OR consumed_at >= issued_at")
            }
        }
        migrator.registerMigration("guardian-journal-v14-remote-command-ledger") { database in
            try database.create(table: "guardian_remote_replay_nonces") { table in
                table.column("nonce_hash", .blob).primaryKey()
                table.column("device_id", .text)
                    .notNull()
                    .references("guardian_remote_devices")
                table.column("command_id", .text).notNull().unique()
                table.column("consumed_at", .double).notNull()
                table.column("expires_at", .double).notNull()
                table.check(sql: "length(nonce_hash) = 32")
                table.check(sql: "expires_at > consumed_at")
            }
            try database.create(table: "guardian_remote_commands") { table in
                table.column("command_id", .text).primaryKey()
                table.column("device_id", .text)
                    .notNull()
                    .references("guardian_remote_devices")
                table.column("generation", .integer).notNull()
                table.column("sequence", .integer).notNull()
                table.column("revocation_epoch", .integer).notNull()
                table.column("nonce_hash", .blob).notNull().unique()
                table.column("payload_digest", .blob).notNull()
                table.column("command_json", .blob).notNull()
                table.column("accepted_at", .double).notNull()
                table.check(sql: "generation > 0")
                table.check(sql: "sequence > 0")
                table.check(sql: "revocation_epoch >= 0")
                table.check(sql: "length(nonce_hash) = 32")
                table.check(sql: "length(payload_digest) = 32")
            }
            try database.create(
                index: "guardian_remote_device_sequence",
                on: "guardian_remote_commands",
                columns: ["device_id", "sequence"],
                unique: true
            )
            try database.create(table: "guardian_remote_command_receipts") { table in
                table.column("command_id", .text)
                    .primaryKey()
                    .references("guardian_remote_commands", onDelete: .cascade)
                table.column("receipt_json", .blob).notNull()
            }
            try database.create(table: "guardian_remote_audit_events") { table in
                table.autoIncrementedPrimaryKey("event_index")
                table.column("kind", .text).notNull()
                table.column("device_id", .text)
                table.column("command_id", .text)
                table.column("reason", .text).notNull()
                table.column("generation", .integer)
                table.column("sequence", .integer)
                table.column("occurred_at", .double).notNull()
                table.check(sql: "length(reason) > 0")
                table.check(sql: "generation IS NULL OR generation > 0")
                table.check(sql: "sequence IS NULL OR sequence >= 0")
            }
        }
        migrator.registerMigration("guardian-journal-v15-remote-command-outcomes") { database in
            try database.create(table: "guardian_remote_command_outcomes") { table in
                table.column("command_id", .text)
                    .primaryKey()
                    .references("guardian_remote_commands", onDelete: .cascade)
                table.column("state", .text).notNull()
                table.column("failure_code", .text)
                table.column("terminal_at", .double)
                table.column("updated_at", .double).notNull()
                table.column("version", .integer).notNull()
                table.check(sql: "state IN ('pending', 'applied', 'failed')")
                table.check(sql: "version > 0")
                table.check(sql: "(state = 'pending' AND failure_code IS NULL AND terminal_at IS NULL) OR (state = 'applied' AND failure_code IS NULL AND terminal_at IS NOT NULL) OR (state = 'failed' AND failure_code IS NOT NULL AND terminal_at IS NOT NULL)")
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_remote_command_outcomes
                    (command_id, state, failure_code, terminal_at, updated_at, version)
                SELECT command_id, 'pending', NULL, NULL, accepted_at, 1
                FROM guardian_remote_commands
                """
            )
        }
        migrator.registerMigration("guardian-journal-v16-daemon-event-replay") { database in
            try database.create(table: "guardian_daemon_events") { table in
                table.column("generation", .integer).notNull()
                table.column("sequence", .integer).notNull()
                table.column("operation_id", .text)
                table.column("emitted_at", .double).notNull()
                table.column("kind", .text).notNull()
                table.primaryKey(["generation", "sequence"])
                table.check(sql: "generation > 0")
                table.check(sql: "sequence > 0")
            }
        }
        migrator.registerMigration("guardian-journal-v17-remote-execution-queue") { database in
            try database.create(table: "guardian_remote_command_payloads") { table in
                table.column("command_id", .text)
                    .primaryKey()
                    .references("guardian_remote_commands", onDelete: .cascade)
                table.column("envelope_version", .integer).notNull()
                table.column("algorithm", .text).notNull()
                table.column("sealed_payload", .blob).notNull()
                table.column("wrapped_dek", .blob).notNull()
                table.column("aad_digest", .blob).notNull()
                table.column("created_at", .double).notNull()
                table.column("destroyed_at", .double)
                table.check(sql: "envelope_version = 1")
                table.check(sql: "algorithm = 'AES.GCM.256'")
                table.check(sql: "length(sealed_payload) > 0")
                table.check(sql: "length(wrapped_dek) > 0")
                table.check(sql: "length(aad_digest) = 32")
            }
            try database.create(table: "guardian_remote_command_executions") { table in
                table.column("command_id", .text)
                    .primaryKey()
                    .references("guardian_remote_commands", onDelete: .cascade)
                table.column("state", .text).notNull()
                table.column("owner_id", .text)
                table.column("lease_generation", .integer).notNull()
                table.column("lease_expires_at", .double)
                table.column("attempt_count", .integer).notNull()
                table.column("next_attempt_at", .double).notNull()
                table.column("daemon_generation", .integer).notNull()
                table.column("updated_at", .double).notNull()
                table.column("version", .integer).notNull()
                table.check(sql: "state IN ('queued', 'claimed', 'effect_prepared', 'reconciling')")
                table.check(sql: "lease_generation >= 0")
                table.check(sql: "attempt_count >= 0")
                table.check(sql: "daemon_generation > 0")
                table.check(sql: "version > 0")
                table.check(sql: "(state = 'queued' AND owner_id IS NULL AND lease_expires_at IS NULL) OR (state != 'queued' AND owner_id IS NOT NULL AND lease_expires_at IS NOT NULL)")
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_remote_audit_events
                    (kind, device_id, command_id, reason, generation, sequence, occurred_at)
                SELECT 'commandFailed', c.device_id, c.command_id,
                       'command.failed.payloadUnavailable', c.generation, c.sequence, o.updated_at
                FROM guardian_remote_command_outcomes o
                JOIN guardian_remote_commands c ON c.command_id = o.command_id
                WHERE o.state = 'pending'
                """
            )
            try database.execute(
                sql: """
                UPDATE guardian_remote_command_outcomes
                SET state = 'failed', failure_code = 'payloadUnavailable',
                    terminal_at = updated_at, version = version + 1
                WHERE state = 'pending'
                """
            )
        }
        migrator.registerMigration("guardian-journal-v18-remote-effect-attempts") { database in
            try database.alter(table: "guardian_remote_command_executions") { table in
                table.add(column: "authority_epoch", .integer)
                table.add(column: "policy_epoch", .integer)
                table.add(column: "target_revision", .text)
                table.add(column: "adapter_id", .text)
                table.add(column: "adapter_version", .text)
                table.add(column: "idempotency_key", .text)
                table.add(column: "evidence_id", .text)
                table.add(column: "effect_prepared_at", .double)
            }
            try database.create(table: "guardian_remote_command_attempts") { table in
                table.column("command_id", .text)
                    .notNull()
                    .references("guardian_remote_commands", onDelete: .cascade)
                table.column("attempt_number", .integer).notNull()
                table.column("lease_generation", .integer).notNull()
                table.column("adapter_id", .text).notNull()
                table.column("adapter_version", .text).notNull()
                table.column("idempotency_key", .text).notNull()
                table.column("authority_epoch", .integer).notNull()
                table.column("policy_epoch", .integer).notNull()
                table.column("target_revision", .text).notNull()
                table.column("evidence_id", .text).notNull()
                table.column("state", .text).notNull()
                table.column("prepared_at", .double).notNull()
                table.column("invoked_at", .double)
                table.column("reconciled_at", .double)
                table.primaryKey(["command_id", "attempt_number"])
                table.check(sql: "attempt_number > 0")
                table.check(sql: "lease_generation > 0")
                table.check(sql: "authority_epoch >= 0")
                table.check(sql: "policy_epoch >= 0")
                table.check(sql: "state IN ('prepared', 'invoked', 'reconciled')")
            }
        }
        migrator.registerMigration("guardian-journal-v19-indeterminate-outcomes") { database in
            try database.create(table: "guardian_remote_command_outcomes_v19") { table in
                table.column("command_id", .text)
                    .primaryKey()
                    .references("guardian_remote_commands", onDelete: .cascade)
                table.column("state", .text).notNull()
                table.column("failure_code", .text)
                table.column("terminal_at", .double)
                table.column("updated_at", .double).notNull()
                table.column("version", .integer).notNull()
                table.check(sql: "state IN ('pending', 'applied', 'failed', 'indeterminate')")
                table.check(sql: "version > 0")
                table.check(sql: "(state = 'pending' AND failure_code IS NULL AND terminal_at IS NULL) OR (state = 'applied' AND failure_code IS NULL AND terminal_at IS NOT NULL) OR (state IN ('failed', 'indeterminate') AND failure_code IS NOT NULL AND terminal_at IS NOT NULL)")
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_remote_command_outcomes_v19
                    (command_id, state, failure_code, terminal_at, updated_at, version)
                SELECT command_id, state, failure_code, terminal_at, updated_at, version
                FROM guardian_remote_command_outcomes
                """
            )
            try database.drop(table: "guardian_remote_command_outcomes")
            try database.execute(
                sql: "ALTER TABLE guardian_remote_command_outcomes_v19 RENAME TO guardian_remote_command_outcomes"
            )
        }
        migrator.registerMigration("guardian-journal-v20-remote-outcome-acks") { database in
            try database.create(table: "guardian_remote_outcome_acks") { table in
                table.column("command_id", .text)
                    .primaryKey()
                    .references("guardian_remote_commands", onDelete: .cascade)
                table.column("device_id", .text)
                    .notNull()
                    .references("guardian_remote_devices")
                table.column("outcome_version", .integer).notNull()
                table.column("acknowledged_at", .double).notNull()
                table.check(sql: "outcome_version > 1")
            }
        }
        migrator.registerMigration("guardian-journal-v21-remote-command-history") { database in
            try database.create(table: "guardian_remote_command_history_index") { table in
                table.column("command_id", .text)
                    .primaryKey()
                    .references("guardian_remote_commands", onDelete: .cascade)
                table.column("device_id", .text)
                    .notNull()
                    .references("guardian_remote_devices")
                table.column("action", .text).notNull()
                table.column("target_thread_id", .text).notNull()
                table.column("expected_generation", .integer).notNull()
                table.column("issued_at", .double).notNull()
                table.column("deadline", .double).notNull()
                table.column("accepted_at", .double).notNull()
                table.check(sql: "action IN ('prompt', 'steer', 'interrupt', 'approve', 'deny', 'repair', 'hardRecover', 'cancelRecovery', 'readFiles', 'openTerminal')")
                table.check(sql: "length(target_thread_id) > 0")
                table.check(sql: "expected_generation > 0")
                table.check(sql: "deadline > issued_at")
            }
            try database.create(
                index: "guardian_remote_history_device_action_time",
                on: "guardian_remote_command_history_index",
                columns: ["device_id", "action", "accepted_at", "command_id"]
            )
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT command_id, device_id, command_json, accepted_at
                FROM guardian_remote_commands
                """
            )
            for row in rows {
                let commandIDText: String = row["command_id"]
                let deviceIDText: String = row["device_id"]
                let commandData: Data = row["command_json"]
                let acceptedAt: Double = row["accepted_at"]
                let command: GuardianStoredRemoteCommand
                do {
                    command = try JSONDecoder().decode(
                        GuardianStoredRemoteCommand.self,
                        from: commandData
                    )
                } catch {
                    throw GuardianJournalError.corruptRemoteTrust
                }
                guard command.commandID.uuidString == commandIDText,
                      command.deviceID.uuidString == deviceIDText,
                      command.isValid,
                      command.targetThreadID.utf8.count <= 1_024,
                      acceptedAt.isFinite else {
                    throw GuardianJournalError.corruptRemoteTrust
                }
                guard command.action != .observe else { continue }
                try database.execute(
                    sql: """
                    INSERT INTO guardian_remote_command_history_index
                        (command_id, device_id, action, target_thread_id,
                         expected_generation, issued_at, deadline, accepted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        commandIDText,
                        deviceIDText,
                        command.action.rawValue,
                        command.targetThreadID,
                        command.expectedGeneration,
                        command.issuedAt.timeIntervalSince1970,
                        command.deadline.timeIntervalSince1970,
                        acceptedAt,
                    ]
                )
            }
        }
    }

    public func issuePairingChallenge(
        _ challenge: GuardianPairingChallenge,
        issuedAt: Date = Date()
    ) throws {
        guard challenge.consumedAt == nil,
              challenge.guardianIdentityHash.count == 32,
              issuedAt.timeIntervalSince1970.isFinite,
              challenge.expiresAt.timeIntervalSince1970.isFinite,
              challenge.expiresAt > issuedAt else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        let nonceHash = Self.remoteNonceHash(challenge.nonce)
        try database.write { database in
            if let existing = try Row.fetchOne(
                database,
                sql: "SELECT * FROM guardian_pairing_challenges WHERE nonce_hash = ?",
                arguments: [nonceHash]
            ) {
                let identity: Data = existing["guardian_identity_hash"]
                let storedIssuedAt: Double = existing["issued_at"]
                let storedExpiresAt: Double = existing["expires_at"]
                let consumedAt: Double? = existing["consumed_at"]
                guard identity == challenge.guardianIdentityHash,
                      storedIssuedAt == issuedAt.timeIntervalSince1970,
                      storedExpiresAt == challenge.expiresAt.timeIntervalSince1970,
                      consumedAt == nil else {
                    throw GuardianJournalError.pairingChallengeConflict
                }
                return
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_pairing_challenges
                    (nonce_hash, guardian_identity_hash, issued_at, expires_at, consumed_at)
                VALUES (?, ?, ?, ?, NULL)
                """,
                arguments: [
                    nonceHash,
                    challenge.guardianIdentityHash,
                    issuedAt.timeIntervalSince1970,
                    challenge.expiresAt.timeIntervalSince1970,
                ]
            )
            try Self.insertRemoteAudit(
                kind: .pairingIssued,
                deviceID: nil,
                commandID: nil,
                reason: "pairing.issued",
                generation: nil,
                sequence: nil,
                at: issuedAt,
                into: database
            )
        }
    }

    public func pairRemoteDevice(
        _ device: GuardianRemoteDevice,
        challenge: GuardianPairingChallenge,
        at date: Date = Date()
    ) throws {
        let nonceHash = Self.remoteNonceHash(challenge.nonce)
        try database.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM guardian_pairing_challenges WHERE nonce_hash = ?",
                arguments: [nonceHash]
            ) else {
                throw GuardianJournalError.pairingChallengeNotFound
            }
            let identityHash: Data = row["guardian_identity_hash"]
            let expiresAtValue: Double = row["expires_at"]
            let consumedAtValue: Double? = row["consumed_at"]
            guard identityHash.count == 32,
                  expiresAtValue.isFinite else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            guard identityHash == challenge.guardianIdentityHash,
                  expiresAtValue == challenge.expiresAt.timeIntervalSince1970 else {
                throw GuardianJournalError.pairingChallengeConflict
            }
            guard consumedAtValue == nil else {
                throw GuardianJournalError.pairingChallengeConsumed
            }
            guard expiresAtValue > date.timeIntervalSince1970 else {
                throw GuardianJournalError.pairingChallengeExpired
            }
            try Self.validateNewRemoteDevice(device, at: date)
            guard try Self.fetchRemoteDevice(id: device.id, from: database) == nil,
                  try Data.fetchOne(
                    database,
                    sql: "SELECT public_key FROM guardian_remote_devices WHERE public_key = ?",
                    arguments: [device.publicKey]
                  ) == nil else {
                throw GuardianJournalError.remoteDeviceConflict(device.id)
            }
            try database.execute(
                sql: """
                UPDATE guardian_pairing_challenges
                SET consumed_at = ?
                WHERE nonce_hash = ? AND consumed_at IS NULL
                """,
                arguments: [date.timeIntervalSince1970, nonceHash]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.pairingChallengeConsumed
            }
            faultInjector?(.remotePairingConsumedBeforeDevice)
            try Self.insertRemoteDevice(device, into: database)
            try Self.insertRemoteAudit(
                kind: .devicePaired,
                deviceID: device.id,
                commandID: nil,
                reason: "device.paired",
                generation: nil,
                sequence: device.lastAcceptedSequence,
                at: date,
                into: database
            )
        }
    }

    public func remoteDevice(id: UUID) throws -> GuardianRemoteDevice? {
        try database.read { database in
            try Self.fetchRemoteDevice(id: id, from: database)
        }
    }

    public func remoteDevices() throws -> [GuardianRemoteDevice] {
        try database.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM guardian_remote_devices ORDER BY paired_at, device_id"
            ).map(Self.decodeRemoteDevice)
        }
    }

    public func revokeRemoteDevice(
        id: UUID,
        expectedRevocationEpoch: UInt64,
        at date: Date = Date()
    ) throws -> GuardianRemoteDevice {
        guard date.timeIntervalSince1970.isFinite,
              expectedRevocationEpoch < UInt64(Int64.max) else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        return try database.write { database in
            guard let current = try Self.fetchRemoteDevice(id: id, from: database) else {
                throw GuardianJournalError.remoteDeviceNotFound(id)
            }
            guard current.revocationEpoch == expectedRevocationEpoch else {
                throw GuardianJournalError.staleRemoteRevocationEpoch(
                    deviceID: id,
                    expected: expectedRevocationEpoch,
                    current: current.revocationEpoch
                )
            }
            if current.status == .revoked { return current }
            let nextEpoch = expectedRevocationEpoch + 1
            try database.execute(
                sql: """
                UPDATE guardian_remote_devices
                SET status = ?, revocation_epoch = ?, last_seen_at = ?
                WHERE device_id = ? AND status = ? AND revocation_epoch = ?
                """,
                arguments: [
                    GuardianRemoteDeviceStatus.revoked.rawValue,
                    Int64(nextEpoch),
                    date.timeIntervalSince1970,
                    id.uuidString,
                    GuardianRemoteDeviceStatus.active.rawValue,
                    Int64(expectedRevocationEpoch),
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.staleRemoteRevocationEpoch(
                    deviceID: id,
                    expected: expectedRevocationEpoch,
                    current: current.revocationEpoch
                )
            }
            faultInjector?(.remoteRevocationUpdatedBeforeAudit)
            try Self.insertRemoteAudit(
                kind: .deviceRevoked,
                deviceID: id,
                commandID: nil,
                reason: "device.revoked",
                generation: nil,
                sequence: current.lastAcceptedSequence,
                at: date,
                into: database
            )
            guard let updated = try Self.fetchRemoteDevice(id: id, from: database) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return updated
        }
    }

    public func reconcileRemoteCommand(
        _ command: GuardianRemoteCommand,
        sealedPayload: GuardianRemoteSealedPayload?,
        currentGeneration: Int64,
        now: Date = Date()
    ) throws -> GuardianRemoteReconciliation {
        guard currentGeneration > 0,
              (command.action == .observe || sealedPayload?.isValid == true),
              command.sequence <= UInt64(Int64.max),
              command.revocationEpoch <= UInt64(Int64.max) else {
            try recordRemoteCommandRejection(
                command,
                reason: .invalidCommand,
                currentGeneration: currentGeneration,
                at: now
            )
            return .rejected(.invalidCommand)
        }
        return try database.write { database in
            guard let device = try Self.fetchRemoteDevice(
                id: command.deviceID,
                from: database
            ) else {
                throw GuardianJournalError.remoteDeviceNotFound(command.deviceID)
            }
            guard device.status == .active else {
                try Self.insertRemoteCommandRejection(
                    command,
                    reason: .deviceRevoked,
                    currentGeneration: currentGeneration,
                    at: now,
                    into: database
                )
                return .rejected(.deviceRevoked)
            }
            if let stored = try Self.fetchRemoteCommand(
                id: command.commandID,
                from: database
            ) {
                guard stored.matches(
                    command,
                    nonceHash: Self.remoteNonceHash(command.nonce)
                ) else {
                    try Self.insertRemoteCommandRejection(
                        command,
                        reason: .commandIDConflict,
                        currentGeneration: currentGeneration,
                        at: now,
                        into: database
                    )
                    return .rejected(.commandIDConflict)
                }
                guard let receipt = try Self.fetchRemoteReceipt(
                    commandID: command.commandID,
                    from: database
                ) else {
                    throw GuardianJournalError.corruptRemoteTrust
                }
                return .duplicate(receipt)
            }

            let nonceHash = Self.remoteNonceHash(command.nonce)
            let consumed = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM guardian_remote_replay_nonces WHERE nonce_hash = ?)",
                arguments: [nonceHash]
            ) ?? false
            let validation = GuardianRemoteCommandValidator().validate(
                command,
                device: device,
                currentGeneration: currentGeneration,
                consumedNonces: consumed ? [command.nonce] : [],
                now: now
            )
            switch validation {
            case let .rejected(reason):
                try Self.insertRemoteCommandRejection(
                    command,
                    reason: Self.auditReason(for: reason),
                    currentGeneration: currentGeneration,
                    at: now,
                    into: database
                )
                return .rejected(reason)
            case let .snapshotRequired(reason):
                try Self.insertRemoteCommandRejection(
                    command,
                    reason: Self.auditReason(for: reason),
                    currentGeneration: currentGeneration,
                    at: now,
                    into: database
                )
                return .snapshotRequired(reason)
            case .accepted:
                break
            }

            let receipt = GuardianRemoteReceipt(
                commandID: command.commandID,
                deviceID: command.deviceID,
                payloadDigest: command.payloadDigest,
                generation: currentGeneration,
                sequence: command.sequence,
                acceptedAt: now
            )
            try database.execute(
                sql: """
                INSERT INTO guardian_remote_replay_nonces
                    (nonce_hash, device_id, command_id, consumed_at, expires_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    nonceHash,
                    command.deviceID.uuidString,
                    command.commandID.uuidString,
                    now.timeIntervalSince1970,
                    command.deadline.timeIntervalSince1970,
                ]
            )
            let commandData = try Self.remoteEncoder().encode(
                GuardianStoredRemoteCommand(
                    command: command,
                    nonceHash: nonceHash
                )
            )
            try database.execute(
                sql: """
                INSERT INTO guardian_remote_commands
                    (command_id, device_id, generation, sequence, revocation_epoch,
                     nonce_hash, payload_digest, command_json, accepted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    command.commandID.uuidString,
                    command.deviceID.uuidString,
                    currentGeneration,
                    Int64(command.sequence),
                    Int64(command.revocationEpoch),
                    nonceHash,
                    command.payloadDigest,
                    commandData,
                    now.timeIntervalSince1970,
                ]
            )
            if command.action != .observe {
                try database.execute(
                    sql: """
                    INSERT INTO guardian_remote_command_history_index
                        (command_id, device_id, action, target_thread_id,
                         expected_generation, issued_at, deadline, accepted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        command.commandID.uuidString,
                        command.deviceID.uuidString,
                        command.action.rawValue,
                        command.targetThreadID,
                        command.expectedGeneration,
                        command.issuedAt.timeIntervalSince1970,
                        command.deadline.timeIntervalSince1970,
                        now.timeIntervalSince1970,
                    ]
                )
                guard let sealedPayload else {
                    throw GuardianJournalError.invalidRemoteRecord
                }
                try database.execute(
                    sql: """
                    INSERT INTO guardian_remote_command_payloads
                        (command_id, envelope_version, algorithm, sealed_payload,
                         wrapped_dek, aad_digest, created_at, destroyed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                    arguments: [
                        command.commandID.uuidString,
                        sealedPayload.envelopeVersion,
                        sealedPayload.algorithm.rawValue,
                        sealedPayload.sealedPayload,
                        sealedPayload.wrappedDEK,
                        sealedPayload.aadDigest,
                        now.timeIntervalSince1970,
                    ]
                )
            }
            faultInjector?(.remoteCommandInsertedBeforeReceipt)
            try database.execute(
                sql: """
                INSERT INTO guardian_remote_command_receipts (command_id, receipt_json)
                VALUES (?, ?)
                """,
                arguments: [
                    command.commandID.uuidString,
                    try Self.remoteEncoder().encode(receipt),
                ]
            )
            if command.action == .observe {
                try database.execute(
                    sql: """
                    INSERT INTO guardian_remote_command_outcomes
                        (command_id, state, failure_code, terminal_at, updated_at, version)
                    VALUES (?, 'applied', NULL, ?, ?, 2)
                    """,
                    arguments: [
                        command.commandID.uuidString,
                        now.timeIntervalSince1970,
                        now.timeIntervalSince1970,
                    ]
                )
            } else {
                try database.execute(
                    sql: """
                    INSERT INTO guardian_remote_command_outcomes
                        (command_id, state, failure_code, terminal_at, updated_at, version)
                    VALUES (?, 'pending', NULL, NULL, ?, 1)
                    """,
                    arguments: [
                        command.commandID.uuidString,
                        now.timeIntervalSince1970,
                    ]
                )
                try database.execute(
                    sql: """
                    INSERT INTO guardian_remote_command_executions
                        (command_id, state, owner_id, lease_generation, lease_expires_at,
                         attempt_count, next_attempt_at, daemon_generation, updated_at, version)
                    VALUES (?, 'queued', NULL, 0, NULL, 0, ?, ?, ?, 1)
                    """,
                    arguments: [
                        command.commandID.uuidString,
                        now.timeIntervalSince1970,
                        currentGeneration,
                        now.timeIntervalSince1970,
                    ]
                )
                faultInjector?(.remoteExecutionQueuedBeforeDeviceAdvance)
            }
            try database.execute(
                sql: """
                UPDATE guardian_remote_devices
                SET last_accepted_sequence = ?, last_seen_at = ?
                WHERE device_id = ? AND status = ?
                  AND revocation_epoch = ? AND last_accepted_sequence = ?
                """,
                arguments: [
                    Int64(command.sequence),
                    now.timeIntervalSince1970,
                    command.deviceID.uuidString,
                    GuardianRemoteDeviceStatus.active.rawValue,
                    Int64(command.revocationEpoch),
                    Int64(device.lastAcceptedSequence),
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            try Self.insertRemoteAudit(
                kind: .commandAccepted,
                deviceID: command.deviceID,
                commandID: command.commandID,
                reason: "command.accepted",
                generation: currentGeneration,
                sequence: command.sequence,
                at: now,
                into: database
            )
            if command.action == .observe {
                faultInjector?(.remoteCommandOutcomeUpdatedBeforeAudit)
                try Self.insertRemoteAudit(
                    kind: .commandApplied,
                    deviceID: command.deviceID,
                    commandID: command.commandID,
                    reason: "command.applied.observe",
                    generation: currentGeneration,
                    sequence: command.sequence,
                    at: now,
                    into: database
                )
            }
            return .accepted(receipt)
        }
    }

    public func recordRemoteCommandRejection(
        _ command: GuardianRemoteCommand,
        reason: GuardianRemoteCommandAuditRejection,
        currentGeneration: Int64,
        at date: Date = Date()
    ) throws {
        try database.write { database in
            try Self.insertRemoteCommandRejection(
                command,
                reason: reason,
                currentGeneration: currentGeneration,
                at: date,
                into: database
            )
        }
    }

    public func remoteAuditEvents(limit: Int = 100) throws -> [GuardianRemoteAuditEvent] {
        guard limit > 0, limit <= 1_000 else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        return try database.read { database in
            let descending = try Row.fetchAll(
                database,
                sql: """
                SELECT * FROM guardian_remote_audit_events
                ORDER BY event_index DESC LIMIT ?
                """,
                arguments: [limit]
            )
            return try descending.reversed().map(Self.decodeRemoteAudit)
        }
    }

    public func recordPairingRejection(
        deviceID: UUID?,
        reason: GuardianPairingAuditRejection,
        at date: Date = Date()
    ) throws {
        try database.write { database in
            try Self.insertRemoteAudit(
                kind: .pairingRejected,
                deviceID: deviceID,
                commandID: nil,
                reason: reason.rawValue,
                generation: nil,
                sequence: nil,
                at: date,
                into: database
            )
        }
    }

    public func remoteReceipt(commandID: UUID) throws -> GuardianRemoteReceipt? {
        try database.read { database in
            try Self.fetchRemoteReceipt(commandID: commandID, from: database)
        }
    }

    public func remoteCommandPayload(
        commandID: UUID
    ) throws -> GuardianRemoteSealedPayload? {
        try database.read { database in
            try Self.fetchRemoteCommandPayload(commandID: commandID, from: database)
        }
    }

    public func claimNextRemoteCommand(
        ownerID: UUID,
        currentDaemonGeneration: Int64,
        now: Date = Date(),
        leaseDuration: TimeInterval
    ) throws -> GuardianRemoteCommandLease? {
        guard currentDaemonGeneration > 0,
              now.timeIntervalSince1970.isFinite,
              leaseDuration > 0,
              leaseDuration <= 30 else {
            throw GuardianJournalError.invalidLeaseDuration
        }
        return try database.write { database in
            try Self.terminalizeIneligibleRemoteCommands(
                currentDaemonGeneration: currentDaemonGeneration,
                at: now,
                in: database,
                faultInjector: faultInjector
            )
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT e.*
                FROM guardian_remote_command_executions e
                JOIN guardian_remote_command_outcomes o ON o.command_id = e.command_id
                JOIN guardian_remote_commands c ON c.command_id = e.command_id
                WHERE o.state = 'pending'
                  AND e.daemon_generation = ?
                  AND e.next_attempt_at <= ?
                  AND (
                    e.state = 'queued'
                    OR (e.state = 'claimed' AND e.lease_expires_at <= ?)
                  )
                ORDER BY c.accepted_at, c.command_id
                LIMIT 100
                """,
                arguments: [
                    currentDaemonGeneration,
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                ]
            )
            for row in rows {
                let commandText: String = row["command_id"]
                guard let commandID = UUID(uuidString: commandText),
                      let stored = try Self.fetchRemoteCommand(
                          id: commandID,
                          from: database
                      ),
                      stored.action != .observe,
                      stored.deadline > now,
                      let device = try Self.fetchRemoteDevice(
                          id: stored.deviceID,
                          from: database
                      ),
                      device.status == .active,
                      device.revocationEpoch == stored.revocationEpoch,
                      let sealedPayload = try Self.fetchRemoteCommandPayload(
                          commandID: commandID,
                          from: database
                      ) else {
                    continue
                }
                let leaseGeneration: Int64 = row["lease_generation"]
                let attemptCount: Int64 = row["attempt_count"]
                let version: Int64 = row["version"]
                guard leaseGeneration >= 0,
                      leaseGeneration < Int64.max,
                      attemptCount >= 0,
                      attemptCount < Int64.max,
                      version > 0,
                      version < Int64.max else {
                    throw GuardianJournalError.corruptRemoteTrust
                }
                let leaseExpiresAt = min(
                    now.addingTimeInterval(leaseDuration),
                    stored.deadline
                )
                guard leaseExpiresAt > now else { continue }
                try database.execute(
                    sql: """
                    UPDATE guardian_remote_command_executions
                    SET state = 'claimed', owner_id = ?,
                        lease_generation = lease_generation + 1,
                        lease_expires_at = ?, attempt_count = attempt_count + 1,
                        updated_at = ?, version = version + 1
                    WHERE command_id = ? AND version = ?
                      AND (
                        state = 'queued'
                        OR (state = 'claimed' AND lease_expires_at <= ?)
                      )
                    """,
                    arguments: [
                        ownerID.uuidString,
                        leaseExpiresAt.timeIntervalSince1970,
                        now.timeIntervalSince1970,
                        commandID.uuidString,
                        version,
                        now.timeIntervalSince1970,
                    ]
                )
                guard database.changesCount == 1 else { continue }
                faultInjector?(.remoteExecutionClaimedBeforeReturn)
                let lease = GuardianRemoteCommandLease(
                    binding: stored.binding,
                    sealedPayload: sealedPayload,
                    ownerID: ownerID,
                    leaseGeneration: leaseGeneration + 1,
                    leaseExpiresAt: leaseExpiresAt,
                    attemptCount: attemptCount + 1,
                    daemonGeneration: currentDaemonGeneration,
                    version: version + 1,
                    purpose: .execution
                )
                guard lease.isValid else {
                    throw GuardianJournalError.corruptRemoteTrust
                }
                return lease
            }
            return nil
        }
    }

    public func renewRemoteCommandLease(
        _ lease: GuardianRemoteCommandLease,
        now: Date = Date(),
        leaseDuration: TimeInterval
    ) throws -> GuardianRemoteCommandLease {
        guard lease.isValid,
              now.timeIntervalSince1970.isFinite,
              leaseDuration > 0,
              leaseDuration <= 30,
              lease.leaseGeneration < Int64.max,
              lease.version < Int64.max else {
            throw GuardianJournalError.invalidLeaseDuration
        }
        let requestedExpiry = now.addingTimeInterval(leaseDuration)
        let renewedExpiry = lease.purpose == .execution
            ? min(requestedExpiry, lease.binding.deadline)
            : requestedExpiry
        guard renewedExpiry > lease.leaseExpiresAt else {
            throw GuardianJournalError.invalidLeaseDuration
        }
        return try database.write { database in
            try database.execute(
                sql: """
                UPDATE guardian_remote_command_executions
                SET lease_generation = lease_generation + 1,
                    lease_expires_at = ?, updated_at = ?, version = version + 1
                WHERE command_id = ? AND state = 'claimed'
                  AND owner_id = ? AND lease_generation = ?
                  AND lease_expires_at = ? AND lease_expires_at > ?
                  AND daemon_generation = ? AND version = ?
                """,
                arguments: [
                    renewedExpiry.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                    lease.binding.commandID.uuidString,
                    lease.ownerID.uuidString,
                    lease.leaseGeneration,
                    lease.leaseExpiresAt.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                    lease.daemonGeneration,
                    lease.version,
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.staleLease(lease.resource)
            }
            return GuardianRemoteCommandLease(
                binding: lease.binding,
                sealedPayload: lease.sealedPayload,
                ownerID: lease.ownerID,
                leaseGeneration: lease.leaseGeneration + 1,
                leaseExpiresAt: renewedExpiry,
                attemptCount: lease.attemptCount,
                daemonGeneration: lease.daemonGeneration,
                version: lease.version + 1,
                purpose: lease.purpose
            )
        }
    }

    public func prepareRemoteCommandEffect(
        _ lease: GuardianRemoteCommandLease,
        adapter: GuardianAdapterIdentity,
        fences: GuardianRemoteEffectFences,
        evidenceID: String,
        at date: Date = Date()
    ) throws -> GuardianRemoteEffectPreparation {
        guard lease.isValid,
              lease.purpose == .execution,
              adapter.isValid,
              fences.isValid,
              !evidenceID.isEmpty,
              evidenceID.utf8.count <= 512,
              date.timeIntervalSince1970.isFinite,
              date < lease.leaseExpiresAt else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        return try database.write { database in
            try database.execute(
                sql: """
                UPDATE guardian_remote_command_executions
                SET state = 'effect_prepared', authority_epoch = ?, policy_epoch = ?,
                    target_revision = ?, adapter_id = ?, adapter_version = ?,
                    idempotency_key = ?, evidence_id = ?, effect_prepared_at = ?,
                    updated_at = ?, version = version + 1
                WHERE command_id = ? AND state = 'claimed'
                  AND owner_id = ? AND lease_generation = ?
                  AND lease_expires_at = ? AND lease_expires_at > ?
                  AND daemon_generation = ? AND version = ?
                """,
                arguments: [
                    fences.authorityEpoch,
                    fences.policyEpoch,
                    fences.targetRevision,
                    adapter.id,
                    adapter.version,
                    lease.binding.commandID.uuidString,
                    evidenceID,
                    date.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                    lease.binding.commandID.uuidString,
                    lease.ownerID.uuidString,
                    lease.leaseGeneration,
                    lease.leaseExpiresAt.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                    lease.daemonGeneration,
                    lease.version,
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.staleLease(lease.resource)
            }
            try database.execute(
                sql: """
                INSERT INTO guardian_remote_command_attempts
                    (command_id, attempt_number, lease_generation,
                     adapter_id, adapter_version, idempotency_key,
                     authority_epoch, policy_epoch, target_revision, evidence_id,
                     state, prepared_at, invoked_at, reconciled_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?, NULL, NULL)
                """,
                arguments: [
                    lease.binding.commandID.uuidString,
                    lease.attemptCount,
                    lease.leaseGeneration,
                    adapter.id,
                    adapter.version,
                    lease.binding.commandID.uuidString,
                    fences.authorityEpoch,
                    fences.policyEpoch,
                    fences.targetRevision,
                    evidenceID,
                    date.timeIntervalSince1970,
                ]
            )
            faultInjector?(.remoteEffectPreparedBeforeReturn)
            let preparedLease = GuardianRemoteCommandLease(
                binding: lease.binding,
                sealedPayload: lease.sealedPayload,
                ownerID: lease.ownerID,
                leaseGeneration: lease.leaseGeneration,
                leaseExpiresAt: lease.leaseExpiresAt,
                attemptCount: lease.attemptCount,
                daemonGeneration: lease.daemonGeneration,
                version: lease.version + 1,
                purpose: .execution
            )
            let preparation = GuardianRemoteEffectPreparation(
                lease: preparedLease,
                adapter: adapter,
                fences: fences,
                idempotencyKey: lease.binding.commandID,
                evidenceID: evidenceID,
                preparedAt: date
            )
            guard preparation.isValid else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return preparation
        }
    }

    public func claimRemoteCommandForReconciliation(
        ownerID: UUID,
        currentDaemonGeneration: Int64,
        now: Date = Date(),
        leaseDuration: TimeInterval
    ) throws -> GuardianRemoteEffectPreparation? {
        guard currentDaemonGeneration > 0,
              now.timeIntervalSince1970.isFinite,
              leaseDuration > 0,
              leaseDuration <= 30 else {
            throw GuardianJournalError.invalidLeaseDuration
        }
        return try database.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                SELECT e.*
                FROM guardian_remote_command_executions e
                JOIN guardian_remote_command_outcomes o ON o.command_id = e.command_id
                JOIN guardian_remote_commands c ON c.command_id = e.command_id
                WHERE o.state = 'pending'
                  AND e.state IN ('effect_prepared', 'reconciling')
                  AND e.lease_expires_at <= ?
                ORDER BY c.accepted_at, c.command_id
                LIMIT 1
                """,
                arguments: [now.timeIntervalSince1970]
            ) else { return nil }
            let commandText: String = row["command_id"]
            guard let commandID = UUID(uuidString: commandText),
                  let stored = try Self.fetchRemoteCommand(id: commandID, from: database),
                  let sealedPayload = try Self.fetchRemoteCommandPayload(
                      commandID: commandID,
                      from: database
                  ) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            let leaseGeneration: Int64 = row["lease_generation"]
            let attemptCount: Int64 = row["attempt_count"]
            let version: Int64 = row["version"]
            let adapterID: String? = row["adapter_id"]
            let adapterVersion: String? = row["adapter_version"]
            let idempotencyText: String? = row["idempotency_key"]
            let authorityEpoch: Int64? = row["authority_epoch"]
            let policyEpoch: Int64? = row["policy_epoch"]
            let targetRevision: String? = row["target_revision"]
            let evidenceID: String? = row["evidence_id"]
            let preparedValue: Double? = row["effect_prepared_at"]
            guard leaseGeneration > 0,
                  leaseGeneration < Int64.max,
                  attemptCount > 0,
                  version > 1,
                  version < Int64.max,
                  let adapterID,
                  let adapterVersion,
                  let idempotencyText,
                  UUID(uuidString: idempotencyText) == commandID,
                  let authorityEpoch,
                  let policyEpoch,
                  let targetRevision,
                  let evidenceID,
                  let preparedValue,
                  preparedValue.isFinite else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            let leaseExpiresAt = now.addingTimeInterval(leaseDuration)
            try database.execute(
                sql: """
                UPDATE guardian_remote_command_executions
                SET state = 'reconciling', owner_id = ?,
                    lease_generation = lease_generation + 1,
                    lease_expires_at = ?, daemon_generation = ?,
                    updated_at = ?, version = version + 1
                WHERE command_id = ? AND version = ?
                  AND state IN ('effect_prepared', 'reconciling')
                  AND lease_expires_at <= ?
                """,
                arguments: [
                    ownerID.uuidString,
                    leaseExpiresAt.timeIntervalSince1970,
                    currentDaemonGeneration,
                    now.timeIntervalSince1970,
                    commandID.uuidString,
                    version,
                    now.timeIntervalSince1970,
                ]
            )
            guard database.changesCount == 1 else { return nil }
            let lease = GuardianRemoteCommandLease(
                binding: stored.binding,
                sealedPayload: sealedPayload,
                ownerID: ownerID,
                leaseGeneration: leaseGeneration + 1,
                leaseExpiresAt: leaseExpiresAt,
                attemptCount: attemptCount,
                daemonGeneration: currentDaemonGeneration,
                version: version + 1,
                purpose: .reconciliation
            )
            let preparation = GuardianRemoteEffectPreparation(
                lease: lease,
                adapter: GuardianAdapterIdentity(
                    id: adapterID,
                    version: adapterVersion
                ),
                fences: GuardianRemoteEffectFences(
                    authorityEpoch: authorityEpoch,
                    policyEpoch: policyEpoch,
                    targetRevision: targetRevision
                ),
                idempotencyKey: commandID,
                evidenceID: evidenceID,
                preparedAt: Date(timeIntervalSince1970: preparedValue)
            )
            guard preparation.isValid else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return preparation
        }
    }

    public func markRemoteCommandInvoked(
        _ preparation: GuardianRemoteEffectPreparation,
        at date: Date = Date()
    ) throws -> GuardianRemoteEffectPreparation {
        let lease = preparation.lease
        guard preparation.isValid,
              lease.purpose == .execution,
              date.timeIntervalSince1970.isFinite,
              date >= preparation.preparedAt,
              date < lease.leaseExpiresAt else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        return try database.write { database in
            try database.execute(
                sql: """
                UPDATE guardian_remote_command_executions
                SET state = 'reconciling', updated_at = ?, version = version + 1
                WHERE command_id = ? AND state = 'effect_prepared'
                  AND owner_id = ? AND lease_generation = ?
                  AND lease_expires_at = ? AND lease_expires_at > ?
                  AND daemon_generation = ? AND version = ?
                """,
                arguments: [
                    date.timeIntervalSince1970,
                    lease.binding.commandID.uuidString,
                    lease.ownerID.uuidString,
                    lease.leaseGeneration,
                    lease.leaseExpiresAt.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                    lease.daemonGeneration,
                    lease.version,
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.staleLease(lease.resource)
            }
            try database.execute(
                sql: """
                UPDATE guardian_remote_command_attempts
                SET state = 'invoked', invoked_at = ?
                WHERE command_id = ? AND attempt_number = ?
                  AND lease_generation = ? AND state = 'prepared'
                """,
                arguments: [
                    date.timeIntervalSince1970,
                    lease.binding.commandID.uuidString,
                    lease.attemptCount,
                    lease.leaseGeneration,
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            faultInjector?(.remoteEffectInvokedBeforeReturn)
            let invokedLease = GuardianRemoteCommandLease(
                binding: lease.binding,
                sealedPayload: lease.sealedPayload,
                ownerID: lease.ownerID,
                leaseGeneration: lease.leaseGeneration,
                leaseExpiresAt: lease.leaseExpiresAt,
                attemptCount: lease.attemptCount,
                daemonGeneration: lease.daemonGeneration,
                version: lease.version + 1,
                purpose: .execution
            )
            return GuardianRemoteEffectPreparation(
                lease: invokedLease,
                adapter: preparation.adapter,
                fences: preparation.fences,
                idempotencyKey: preparation.idempotencyKey,
                evidenceID: preparation.evidenceID,
                preparedAt: preparation.preparedAt
            )
        }
    }

    public func remoteCommandHistory(
        deviceID: UUID
    ) throws -> GuardianRemoteCommandHistoryPage {
        try database.read { database in
            guard try Self.fetchRemoteDevice(id: deviceID, from: database) != nil else {
                throw GuardianJournalError.remoteDeviceNotFound(deviceID)
            }
            let totalCount = try Int.fetchOne(
                database,
                sql: """
                SELECT COUNT(*)
                FROM guardian_remote_command_history_index
                WHERE device_id = ? AND action != ?
                """,
                arguments: [deviceID.uuidString, GuardianRemoteAction.observe.rawValue]
            ) ?? 0
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT h.command_id AS history_command_id,
                       h.device_id AS history_device_id,
                       h.action AS history_action,
                       h.target_thread_id AS history_target_thread_id,
                       h.expected_generation AS history_expected_generation,
                       h.issued_at AS history_issued_at,
                       h.deadline AS history_deadline,
                       h.accepted_at AS history_accepted_at,
                       c.generation AS command_generation,
                       c.sequence AS command_sequence,
                       c.revocation_epoch AS command_revocation_epoch,
                       c.nonce_hash AS command_nonce_hash,
                       c.payload_digest AS command_payload_digest,
                       c.command_json AS command_json,
                       c.accepted_at AS command_accepted_at,
                       r.receipt_json AS receipt_json,
                       o.state AS state,
                       o.failure_code AS failure_code,
                       o.terminal_at AS terminal_at,
                       o.updated_at AS updated_at,
                       o.version AS version
                FROM guardian_remote_command_history_index h
                JOIN guardian_remote_commands c ON c.command_id = h.command_id
                JOIN guardian_remote_command_receipts r ON r.command_id = h.command_id
                JOIN guardian_remote_command_outcomes o ON o.command_id = h.command_id
                WHERE h.device_id = ? AND h.action != ?
                ORDER BY h.accepted_at DESC, h.command_id DESC
                LIMIT ?
                """,
                arguments: [
                    deviceID.uuidString,
                    GuardianRemoteAction.observe.rawValue,
                    GuardianRemoteCommandHistoryPage.maximumItems,
                ]
            )
            let items = try rows.map(Self.decodeRemoteCommandHistoryItem)
            let page = GuardianRemoteCommandHistoryPage(
                items: items,
                totalCount: totalCount,
                completeness: totalCount == items.count ? .complete : .truncated
            )
            guard page.isValid(for: deviceID) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return page
        }
    }

    public func remoteCommandOutcome(
        commandID: UUID
    ) throws -> GuardianRemoteCommandOutcome? {
        try database.read { database in
            guard let receipt = try Self.fetchRemoteReceipt(
                commandID: commandID,
                from: database
            ) else { return nil }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM guardian_remote_command_outcomes WHERE command_id = ?",
                arguments: [commandID.uuidString]
            ) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return try Self.decodeRemoteCommandOutcome(row, receipt: receipt)
        }
    }

    public func ackRemoteCommandOutcome(
        deviceID: UUID,
        commandID: UUID,
        at date: Date = Date()
    ) throws -> GuardianRemoteOutcomeAcknowledgement {
        guard let acknowledgement = try ackRemoteCommandOutcomes(
            deviceID: deviceID,
            commandIDs: [commandID],
            at: date
        ).first else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        return acknowledgement
    }

    public func ackRemoteCommandOutcomes(
        deviceID: UUID,
        commandIDs: [UUID],
        at date: Date = Date()
    ) throws -> [GuardianRemoteOutcomeAcknowledgement] {
        guard date.timeIntervalSince1970.isFinite,
              commandIDs.count <= 100,
              Set(commandIDs).count == commandIDs.count else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        guard !commandIDs.isEmpty else { return [] }
        let acknowledgements = try database.write { database in
            try commandIDs.map { commandID in
                try Self.acknowledgeRemoteCommandOutcome(
                    deviceID: deviceID,
                    commandID: commandID,
                    at: date,
                    in: database,
                    faultInjector: faultInjector
                )
            }
        }
        _ = try? database.writeWithoutTransaction { database in
            try database.checkpoint(.truncate)
        }
        return acknowledgements
    }

    private static func acknowledgeRemoteCommandOutcome(
        deviceID: UUID,
        commandID: UUID,
        at date: Date,
        in database: Database,
        faultInjector: GuardianJournalFaultInjector?
    ) throws -> GuardianRemoteOutcomeAcknowledgement {
        guard let receipt = try fetchRemoteReceipt(
            commandID: commandID,
            from: database
        ) else {
            throw GuardianJournalError.remoteCommandNotFound(commandID)
        }
        guard receipt.deviceID == deviceID,
              let device = try fetchRemoteDevice(id: deviceID, from: database),
              device.status == .active else {
            throw GuardianJournalError.remoteOutcomeAcknowledgementDenied(commandID)
        }
        guard let outcomeRow = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_remote_command_outcomes WHERE command_id = ?",
            arguments: [commandID.uuidString]
        ) else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        let outcome = try decodeRemoteCommandOutcome(outcomeRow, receipt: receipt)
        guard outcome.state != .pending else {
            throw GuardianJournalError.remoteOutcomeAcknowledgementDenied(commandID)
        }
        let version: Int64 = outcomeRow["version"]
        guard version > 1 else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        if let existing = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_remote_outcome_acks WHERE command_id = ?",
            arguments: [commandID.uuidString]
        ) {
            let storedDeviceText: String = existing["device_id"]
            let storedVersion: Int64 = existing["outcome_version"]
            let storedAtValue: Double = existing["acknowledged_at"]
            guard UUID(uuidString: storedDeviceText) == deviceID,
                  storedVersion == version,
                  storedAtValue.isFinite else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return GuardianRemoteOutcomeAcknowledgement(
                commandID: commandID,
                deviceID: deviceID,
                outcomeVersion: storedVersion,
                acknowledgedAt: Date(timeIntervalSince1970: storedAtValue)
            )
        }
        try database.execute(
            sql: """
            INSERT INTO guardian_remote_outcome_acks
                (command_id, device_id, outcome_version, acknowledged_at)
            VALUES (?, ?, ?, ?)
            """,
            arguments: [
                commandID.uuidString,
                deviceID.uuidString,
                version,
                date.timeIntervalSince1970,
            ]
        )
        faultInjector?(.remoteOutcomeAckInsertedBeforePayloadDestroy)
        try database.execute(
            sql: "DELETE FROM guardian_remote_command_payloads WHERE command_id = ?",
            arguments: [commandID.uuidString]
        )
        try insertRemoteAudit(
            kind: .commandOutcomeAcknowledged,
            deviceID: deviceID,
            commandID: commandID,
            reason: "command.outcome.acknowledged",
            generation: receipt.generation,
            sequence: receipt.sequence,
            at: date,
            into: database
        )
        return GuardianRemoteOutcomeAcknowledgement(
            commandID: commandID,
            deviceID: deviceID,
            outcomeVersion: version,
            acknowledgedAt: date
        )
    }

    public func completeRemoteCommand(
        _ lease: GuardianRemoteCommandLease,
        completion: GuardianRemoteCommandCompletion,
        at date: Date = Date()
    ) throws -> GuardianRemoteCommandOutcome {
        let commandID = lease.binding.commandID
        guard lease.isValid,
              date.timeIntervalSince1970.isFinite else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        return try database.write { database in
            guard let receipt = try Self.fetchRemoteReceipt(
                commandID: commandID,
                from: database
            ) else {
                throw GuardianJournalError.remoteCommandNotFound(commandID)
            }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM guardian_remote_command_outcomes WHERE command_id = ?",
                arguments: [commandID.uuidString]
            ) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            let current = try Self.decodeRemoteCommandOutcome(row, receipt: receipt)
            switch (current.state, completion) {
            case (.applied, .applied):
                return current
            case let (.failed(existing, _), .failed(requested)) where existing == requested:
                return current
            case let (.indeterminate(existing, _), .indeterminate(requested))
                where existing == requested:
                return current
            case (.pending, _):
                break
            default:
                throw GuardianJournalError.remoteCommandOutcomeConflict(commandID)
            }

            let ownsLiveLease = try Bool.fetchOne(
                database,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM guardian_remote_command_executions
                    WHERE command_id = ? AND state IN ('claimed', 'effect_prepared', 'reconciling')
                      AND owner_id = ? AND lease_generation = ?
                      AND lease_expires_at = ? AND lease_expires_at > ?
                      AND daemon_generation = ? AND version = ?
                )
                """,
                arguments: [
                    commandID.uuidString,
                    lease.ownerID.uuidString,
                    lease.leaseGeneration,
                    lease.leaseExpiresAt.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                    lease.daemonGeneration,
                    lease.version,
                ]
            ) ?? false
            guard ownsLiveLease else {
                throw GuardianJournalError.staleLease(lease.resource)
            }

            let version: Int64 = row["version"]
            let state: String
            let failureCode: String?
            let auditKind: GuardianRemoteAuditKind
            let auditReason: String
            let outcomeState: GuardianRemoteCommandOutcomeState
            switch completion {
            case .applied:
                state = "applied"
                failureCode = nil
                auditKind = .commandApplied
                auditReason = "command.applied"
                outcomeState = .applied(at: date)
            case let .failed(code):
                state = "failed"
                failureCode = code.rawValue
                auditKind = .commandFailed
                auditReason = "command.failed.\(code.rawValue)"
                outcomeState = .failed(code: code, at: date)
            case let .indeterminate(code):
                state = "indeterminate"
                failureCode = code.rawValue
                auditKind = .commandIndeterminate
                auditReason = "command.indeterminate.\(code.rawValue)"
                outcomeState = .indeterminate(code: code, at: date)
            }
            try database.execute(
                sql: """
                UPDATE guardian_remote_command_outcomes
                SET state = ?, failure_code = ?, terminal_at = ?, updated_at = ?, version = version + 1
                WHERE command_id = ? AND state = 'pending' AND version = ?
                """,
                arguments: [
                    state,
                    failureCode,
                    date.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                    commandID.uuidString,
                    version,
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.remoteCommandOutcomeConflict(commandID)
            }
            faultInjector?(.remoteCommandOutcomeUpdatedBeforeAudit)
            try Self.insertRemoteAudit(
                kind: auditKind,
                deviceID: receipt.deviceID,
                commandID: receipt.commandID,
                reason: auditReason,
                generation: receipt.generation,
                sequence: receipt.sequence,
                at: date,
                into: database
            )
            try database.execute(
                sql: """
                DELETE FROM guardian_remote_command_executions
                WHERE command_id = ? AND state IN ('claimed', 'effect_prepared', 'reconciling')
                  AND owner_id = ? AND lease_generation = ? AND version = ?
                """,
                arguments: [
                    commandID.uuidString,
                    lease.ownerID.uuidString,
                    lease.leaseGeneration,
                    lease.version,
                ]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.staleLease(lease.resource)
            }
            return GuardianRemoteCommandOutcome(
                receipt: receipt,
                state: outcomeState
            )
        }
    }

    private static func decodeRemoteCommandHistoryItem(
        _ row: Row
    ) throws -> GuardianRemoteCommandHistoryItem {
        let commandIDText: String = row["history_command_id"]
        let deviceIDText: String = row["history_device_id"]
        let actionText: String = row["history_action"]
        let targetThreadID: String = row["history_target_thread_id"]
        let expectedGeneration: Int64 = row["history_expected_generation"]
        let issuedAtValue: Double = row["history_issued_at"]
        let deadlineValue: Double = row["history_deadline"]
        let historyAcceptedAtValue: Double = row["history_accepted_at"]
        let commandGeneration: Int64 = row["command_generation"]
        let commandSequence: Int64 = row["command_sequence"]
        let commandRevocationEpoch: Int64 = row["command_revocation_epoch"]
        let commandNonceHash: Data = row["command_nonce_hash"]
        let commandPayloadDigest: Data = row["command_payload_digest"]
        let commandAcceptedAtValue: Double = row["command_accepted_at"]
        let commandData: Data = row["command_json"]
        let receiptData: Data = row["receipt_json"]
        let outcomeVersion: Int64 = row["version"]
        let updatedAtValue: Double = row["updated_at"]
        let command: GuardianStoredRemoteCommand
        let receipt: GuardianRemoteReceipt
        do {
            command = try JSONDecoder().decode(
                GuardianStoredRemoteCommand.self,
                from: commandData
            )
            receipt = try JSONDecoder().decode(
                GuardianRemoteReceipt.self,
                from: receiptData
            )
        } catch {
            throw GuardianJournalError.corruptRemoteTrust
        }
        guard let commandID = UUID(uuidString: commandIDText),
              let deviceID = UUID(uuidString: deviceIDText),
              let action = GuardianRemoteAction(rawValue: actionText),
              expectedGeneration > 0,
              issuedAtValue.isFinite,
              deadlineValue.isFinite,
              deadlineValue > issuedAtValue,
              historyAcceptedAtValue.isFinite,
              commandAcceptedAtValue.isFinite,
              updatedAtValue.isFinite,
              commandSequence > 0,
              commandRevocationEpoch >= 0,
              command.commandID == commandID,
              command.deviceID == deviceID,
              command.action == action,
              command.targetThreadID == targetThreadID,
              command.expectedGeneration == expectedGeneration,
              command.issuedAt.timeIntervalSince1970 == issuedAtValue,
              command.deadline.timeIntervalSince1970 == deadlineValue,
              command.expectedGeneration == commandGeneration,
              command.sequence <= UInt64(Int64.max),
              Int64(command.sequence) == commandSequence,
              command.revocationEpoch <= UInt64(Int64.max),
              Int64(command.revocationEpoch) == commandRevocationEpoch,
              command.nonceHash == commandNonceHash,
              command.payloadDigest == commandPayloadDigest,
              command.isValid,
              targetThreadID.utf8.count <= 1_024,
              historyAcceptedAtValue == commandAcceptedAtValue,
              receipt.commandID == commandID,
              receipt.deviceID == deviceID,
              receipt.payloadDigest == commandPayloadDigest,
              receipt.generation == commandGeneration,
              receipt.sequence == command.sequence,
              receipt.acceptedAt.timeIntervalSince1970 == commandAcceptedAtValue else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        let outcome = try decodeRemoteCommandOutcome(row, receipt: receipt)
        let item = GuardianRemoteCommandHistoryItem(
            action: action,
            targetThreadID: targetThreadID,
            expectedGeneration: expectedGeneration,
            issuedAt: Date(timeIntervalSince1970: issuedAtValue),
            deadline: Date(timeIntervalSince1970: deadlineValue),
            outcome: outcome,
            outcomeVersion: outcomeVersion,
            updatedAt: Date(timeIntervalSince1970: updatedAtValue)
        )
        guard item.isValid else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        return item
    }

    private static func decodeRemoteCommandOutcome(
        _ row: Row,
        receipt: GuardianRemoteReceipt
    ) throws -> GuardianRemoteCommandOutcome {
        let stateText: String = row["state"]
        let failureText: String? = row["failure_code"]
        let terminalValue: Double? = row["terminal_at"]
        let updatedValue: Double = row["updated_at"]
        let version: Int64 = row["version"]
        guard updatedValue.isFinite,
              version > 0 else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        let state: GuardianRemoteCommandOutcomeState
        switch (stateText, failureText, terminalValue) {
        case ("pending", nil, nil):
            state = .pending
        case let ("applied", nil, terminal?):
            guard terminal.isFinite else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            state = .applied(at: Date(timeIntervalSince1970: terminal))
        case let ("failed", failure?, terminal?):
            guard terminal.isFinite,
                  let code = GuardianRemoteCommandFailureCode(rawValue: failure) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            state = .failed(code: code, at: Date(timeIntervalSince1970: terminal))
        case let ("indeterminate", failure?, terminal?):
            guard terminal.isFinite,
                  let code = GuardianRemoteCommandFailureCode(rawValue: failure) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            state = .indeterminate(code: code, at: Date(timeIntervalSince1970: terminal))
        default:
            throw GuardianJournalError.corruptRemoteTrust
        }
        return GuardianRemoteCommandOutcome(receipt: receipt, state: state)
    }

    private static func validateNewRemoteDevice(
        _ device: GuardianRemoteDevice,
        at date: Date
    ) throws {
        let knownCapabilities: UInt64 = (1 << 7) - 1
        guard device.publicKey.count == 32,
              !device.capabilities.isEmpty,
              device.capabilities.contains(.observe),
              device.capabilities.rawValue & ~knownCapabilities == 0,
              device.status == .active,
              device.pairingEpoch > 0,
              device.pairingEpoch <= UInt64(Int64.max),
              device.revocationEpoch == 0,
              device.lastAcceptedSequence == 0,
              device.pairedAt == date,
              device.pairedAt.timeIntervalSince1970.isFinite,
              device.lastSeenAt == nil else {
            throw GuardianJournalError.invalidRemoteRecord
        }
    }

    private static func insertRemoteDevice(
        _ device: GuardianRemoteDevice,
        into database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO guardian_remote_devices
                (device_id, public_key, capabilities, status, pairing_epoch,
                 revocation_epoch, last_accepted_sequence, paired_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                device.id.uuidString,
                device.publicKey,
                Int64(device.capabilities.rawValue),
                device.status.rawValue,
                Int64(device.pairingEpoch),
                Int64(device.revocationEpoch),
                Int64(device.lastAcceptedSequence),
                device.pairedAt.timeIntervalSince1970,
                device.lastSeenAt?.timeIntervalSince1970,
            ]
        )
    }

    private static func fetchRemoteDevice(
        id: UUID,
        from database: Database
    ) throws -> GuardianRemoteDevice? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_remote_devices WHERE device_id = ?",
            arguments: [id.uuidString]
        ) else { return nil }
        return try decodeRemoteDevice(row)
    }

    private static func decodeRemoteDevice(_ row: Row) throws -> GuardianRemoteDevice {
        let idText: String = row["device_id"]
        let publicKey: Data = row["public_key"]
        let capabilitiesValue: Int64 = row["capabilities"]
        let statusText: String = row["status"]
        let pairingEpochValue: Int64 = row["pairing_epoch"]
        let revocationEpochValue: Int64 = row["revocation_epoch"]
        let sequenceValue: Int64 = row["last_accepted_sequence"]
        let pairedAtValue: Double = row["paired_at"]
        let lastSeenAtValue: Double? = row["last_seen_at"]
        let knownCapabilities: UInt64 = (1 << 7) - 1
        guard let id = UUID(uuidString: idText),
              publicKey.count == 32,
              capabilitiesValue > 0,
              let status = GuardianRemoteDeviceStatus(rawValue: statusText),
              pairingEpochValue > 0,
              revocationEpochValue >= 0,
              sequenceValue >= 0,
              pairedAtValue.isFinite,
              lastSeenAtValue?.isFinite != false else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        let capabilities = GuardianRemoteCapabilities(rawValue: UInt64(capabilitiesValue))
        guard capabilities.contains(.observe),
              capabilities.rawValue & ~knownCapabilities == 0 else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        return GuardianRemoteDevice(
            id: id,
            publicKey: publicKey,
            capabilities: capabilities,
            status: status,
            pairingEpoch: UInt64(pairingEpochValue),
            revocationEpoch: UInt64(revocationEpochValue),
            lastAcceptedSequence: UInt64(sequenceValue),
            pairedAt: Date(timeIntervalSince1970: pairedAtValue),
            lastSeenAt: lastSeenAtValue.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func fetchRemoteCommandPayload(
        commandID: UUID,
        from database: Database
    ) throws -> GuardianRemoteSealedPayload? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_remote_command_payloads WHERE command_id = ?",
            arguments: [commandID.uuidString]
        ) else { return nil }
        let envelopeVersion: Int = row["envelope_version"]
        let algorithmText: String = row["algorithm"]
        let sealedPayload: Data = row["sealed_payload"]
        let wrappedDEK: Data = row["wrapped_dek"]
        let aadDigest: Data = row["aad_digest"]
        let createdAt: Double = row["created_at"]
        let destroyedAt: Double? = row["destroyed_at"]
        guard createdAt.isFinite,
              destroyedAt == nil,
              let algorithm = GuardianRemotePayloadAlgorithm(rawValue: algorithmText) else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        let envelope = GuardianRemoteSealedPayload(
            envelopeVersion: envelopeVersion,
            algorithm: algorithm,
            sealedPayload: sealedPayload,
            wrappedDEK: wrappedDEK,
            aadDigest: aadDigest
        )
        guard envelope.isValid else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        return envelope
    }

    private static func terminalizeIneligibleRemoteCommands(
        currentDaemonGeneration: Int64,
        at date: Date,
        in database: Database,
        faultInjector: GuardianJournalFaultInjector?
    ) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT e.command_id, e.daemon_generation
            FROM guardian_remote_command_executions e
            JOIN guardian_remote_command_outcomes o ON o.command_id = e.command_id
            WHERE o.state = 'pending' AND e.state IN ('queued', 'claimed')
            ORDER BY e.command_id
            """
        )
        for row in rows {
            let commandText: String = row["command_id"]
            let acceptedGeneration: Int64 = row["daemon_generation"]
            guard let commandID = UUID(uuidString: commandText),
                  let stored = try Self.fetchRemoteCommand(
                      id: commandID,
                      from: database
                  ) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            guard stored.action != .observe else { continue }
            let failure: GuardianRemoteCommandFailureCode?
            if acceptedGeneration != currentDaemonGeneration {
                failure = .generationChanged
            } else if stored.deadline <= date {
                failure = .deadlineExceeded
            } else {
                guard let device = try Self.fetchRemoteDevice(
                    id: stored.deviceID,
                    from: database
                ) else {
                    throw GuardianJournalError.corruptRemoteTrust
                }
                failure = device.status == .active
                    && device.revocationEpoch == stored.revocationEpoch
                    ? nil
                    : .policyDenied
            }
            guard let failure else { continue }
            try database.execute(
                sql: """
                UPDATE guardian_remote_command_outcomes
                SET state = 'failed', failure_code = ?, terminal_at = ?,
                    updated_at = ?, version = version + 1
                WHERE command_id = ? AND state = 'pending'
                """,
                arguments: [
                    failure.rawValue,
                    date.timeIntervalSince1970,
                    date.timeIntervalSince1970,
                    commandID.uuidString,
                ]
            )
            guard database.changesCount == 1 else { continue }
            faultInjector?(.remoteCommandOutcomeUpdatedBeforeAudit)
            try Self.insertRemoteAudit(
                kind: .commandFailed,
                deviceID: stored.deviceID,
                commandID: commandID,
                reason: "command.failed.\(failure.rawValue)",
                generation: acceptedGeneration,
                sequence: stored.sequence,
                at: date,
                into: database
            )
            try database.execute(
                sql: "DELETE FROM guardian_remote_command_executions WHERE command_id = ?",
                arguments: [commandID.uuidString]
            )
            guard database.changesCount == 1 else {
                throw GuardianJournalError.corruptRemoteTrust
            }
        }
    }

    private static func fetchRemoteCommand(
        id: UUID,
        from database: Database
    ) throws -> GuardianStoredRemoteCommand? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM guardian_remote_commands WHERE command_id = ?",
            arguments: [id.uuidString]
        ) else { return nil }
        let data: Data = row["command_json"]
        do {
            let command = try JSONDecoder().decode(
                GuardianStoredRemoteCommand.self,
                from: data
            )
            let rowDeviceID: String = row["device_id"]
            let rowGeneration: Int64 = row["generation"]
            let rowSequence: Int64 = row["sequence"]
            let rowRevocationEpoch: Int64 = row["revocation_epoch"]
            let rowNonceHash: Data = row["nonce_hash"]
            let rowPayloadDigest: Data = row["payload_digest"]
            guard command.commandID == id,
                  command.deviceID.uuidString == rowDeviceID,
                  command.expectedGeneration == rowGeneration,
                  command.sequence <= UInt64(Int64.max),
                  Int64(command.sequence) == rowSequence,
                  command.revocationEpoch <= UInt64(Int64.max),
                  Int64(command.revocationEpoch) == rowRevocationEpoch,
                  command.nonceHash == rowNonceHash,
                  command.payloadDigest == rowPayloadDigest,
                  command.isValid else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return command
        } catch let error as GuardianJournalError {
            throw error
        } catch {
            throw GuardianJournalError.corruptRemoteTrust
        }
    }

    private static func fetchRemoteReceipt(
        commandID: UUID,
        from database: Database
    ) throws -> GuardianRemoteReceipt? {
        guard let data = try Data.fetchOne(
            database,
            sql: """
            SELECT receipt_json FROM guardian_remote_command_receipts WHERE command_id = ?
            """,
            arguments: [commandID.uuidString]
        ) else { return nil }
        do {
            let receipt = try JSONDecoder().decode(GuardianRemoteReceipt.self, from: data)
            guard receipt.commandID == commandID,
                  receipt.payloadDigest.count == 32,
                  receipt.generation > 0,
                  receipt.acceptedAt.timeIntervalSince1970.isFinite else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return receipt
        } catch let error as GuardianJournalError {
            throw error
        } catch {
            throw GuardianJournalError.corruptRemoteTrust
        }
    }

    private static func insertRemoteAudit(
        kind: GuardianRemoteAuditKind,
        deviceID: UUID?,
        commandID: UUID?,
        reason: String,
        generation: Int64?,
        sequence: UInt64?,
        at date: Date,
        into database: Database
    ) throws {
        guard !reason.isEmpty,
              date.timeIntervalSince1970.isFinite,
              generation.map({ $0 > 0 }) ?? true,
              sequence.map({ $0 <= UInt64(Int64.max) }) ?? true else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        try database.execute(
            sql: """
            INSERT INTO guardian_remote_audit_events
                (kind, device_id, command_id, reason, generation, sequence, occurred_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                kind.rawValue,
                deviceID?.uuidString,
                commandID?.uuidString,
                reason,
                generation,
                sequence.map(Int64.init),
                date.timeIntervalSince1970,
            ]
        )
    }

    private static func insertRemoteCommandRejection(
        _ command: GuardianRemoteCommand,
        reason: GuardianRemoteCommandAuditRejection,
        currentGeneration: Int64,
        at date: Date,
        into database: Database
    ) throws {
        try insertRemoteAudit(
            kind: .commandRejected,
            deviceID: command.deviceID,
            commandID: command.commandID,
            reason: reason.rawValue,
            generation: currentGeneration > 0 ? currentGeneration : nil,
            sequence: command.sequence <= UInt64(Int64.max) ? command.sequence : nil,
            at: date,
            into: database
        )
    }

    private static func auditReason(
        for reason: GuardianRemoteCommandRejection
    ) -> GuardianRemoteCommandAuditRejection {
        switch reason {
        case .unsupportedProtocol: .unsupportedProtocol
        case .deviceIdentityMismatch: .deviceIdentityMismatch
        case .deviceRevoked: .deviceRevoked
        case .staleRevocationEpoch: .staleRevocationEpoch
        case .commandExpired: .commandExpired
        case .invalidCommand: .invalidCommand
        case .replayedNonce: .replayedNonce
        case .staleSequence: .staleSequence
        case .missingCapability: .missingCapability
        case .remoteForceForbidden: .remoteForceForbidden
        case .commandIDConflict: .commandIDConflict
        }
    }

    private static func auditReason(
        for reason: GuardianRemoteSnapshotReason
    ) -> GuardianRemoteCommandAuditRejection {
        switch reason {
        case .generationChanged: .generationChanged
        case .sequenceGap: .sequenceGap
        case .sessionAwaitingSnapshot: .sessionAwaitingSnapshot
        case .unknownSession: .unknownSession
        }
    }

    private static func decodeRemoteAudit(_ row: Row) throws -> GuardianRemoteAuditEvent {
        let index: Int64 = row["event_index"]
        let kindText: String = row["kind"]
        let deviceText: String? = row["device_id"]
        let commandText: String? = row["command_id"]
        let reason: String = row["reason"]
        let generation: Int64? = row["generation"]
        let sequenceValue: Int64? = row["sequence"]
        let occurredAtValue: Double = row["occurred_at"]
        guard index > 0,
              let kind = GuardianRemoteAuditKind(rawValue: kindText),
              !reason.isEmpty,
              generation.map({ $0 > 0 }) ?? true,
              sequenceValue.map({ $0 >= 0 }) ?? true,
              occurredAtValue.isFinite else {
            throw GuardianJournalError.corruptRemoteTrust
        }
        let deviceID = try deviceText.map { text -> UUID in
            guard let value = UUID(uuidString: text) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return value
        }
        let commandID = try commandText.map { text -> UUID in
            guard let value = UUID(uuidString: text) else {
                throw GuardianJournalError.corruptRemoteTrust
            }
            return value
        }
        return GuardianRemoteAuditEvent(
            index: index,
            kind: kind,
            deviceID: deviceID,
            commandID: commandID,
            reason: reason,
            generation: generation,
            sequence: sequenceValue.map(UInt64.init),
            occurredAt: Date(timeIntervalSince1970: occurredAtValue)
        )
    }

    private static func remoteNonceHash(_ nonce: UUID) -> Data {
        Data(SHA256.hash(data: Data(nonce.uuidString.lowercased().utf8)))
    }

    private static func remoteEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct GuardianStoredRemoteCommand: Codable, Equatable {
    let protocolVersion: GuardianRemoteProtocolVersion
    let commandID: UUID
    let deviceID: UUID
    let expectedGeneration: Int64
    let sequence: UInt64
    let nonceHash: Data
    let issuedAt: Date
    let deadline: Date
    let revocationEpoch: UInt64
    let targetThreadID: String
    let action: GuardianRemoteAction
    let force: Bool
    let payloadDigest: Data

    init(command: GuardianRemoteCommand, nonceHash: Data) {
        protocolVersion = command.protocolVersion
        commandID = command.commandID
        deviceID = command.deviceID
        expectedGeneration = command.expectedGeneration
        sequence = command.sequence
        self.nonceHash = nonceHash
        issuedAt = command.issuedAt
        deadline = command.deadline
        revocationEpoch = command.revocationEpoch
        targetThreadID = command.targetThreadID
        action = command.action
        force = command.force
        payloadDigest = command.payloadDigest
    }

    var isValid: Bool {
        protocolVersion == .current
            && expectedGeneration > 0
            && sequence > 0
            && nonceHash.count == 32
            && issuedAt.timeIntervalSince1970.isFinite
            && deadline.timeIntervalSince1970.isFinite
            && deadline > issuedAt
            && !targetThreadID.isEmpty
            && !force
            && payloadDigest.count == 32
    }

    var binding: GuardianRemotePayloadBinding {
        GuardianRemotePayloadBinding(
            command: GuardianRemoteCommand(
                protocolVersion: protocolVersion,
                commandID: commandID,
                deviceID: deviceID,
                expectedGeneration: expectedGeneration,
                sequence: sequence,
                nonce: UUID(),
                issuedAt: issuedAt,
                deadline: deadline,
                revocationEpoch: revocationEpoch,
                targetThreadID: targetThreadID,
                action: action,
                force: force,
                payloadDigest: payloadDigest
            )
        )
    }

    func matches(_ command: GuardianRemoteCommand, nonceHash: Data) -> Bool {
        self == GuardianStoredRemoteCommand(command: command, nonceHash: nonceHash)
    }
}
