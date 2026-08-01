import CryptoKit
import Foundation

public struct GuardianRemoteProtocolVersion: Codable, Equatable, Hashable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let current = GuardianRemoteProtocolVersion(major: 1, minor: 0)
}

public struct GuardianRemoteCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let observe = GuardianRemoteCapabilities(rawValue: 1 << 0)
    public static let prompt = GuardianRemoteCapabilities(rawValue: 1 << 1)
    public static let approve = GuardianRemoteCapabilities(rawValue: 1 << 2)
    public static let repair = GuardianRemoteCapabilities(rawValue: 1 << 3)
    public static let policyRecovery = GuardianRemoteCapabilities(rawValue: 1 << 4)
    public static let files = GuardianRemoteCapabilities(rawValue: 1 << 5)
    public static let terminal = GuardianRemoteCapabilities(rawValue: 1 << 6)
}

public enum GuardianRemoteDeviceStatus: String, Codable, Equatable, Sendable {
    case active
    case revoked
}

public struct GuardianRemoteDevice: Codable, Equatable, Sendable {
    public let id: UUID
    public let publicKey: Data
    public let capabilities: GuardianRemoteCapabilities
    public let status: GuardianRemoteDeviceStatus
    public let pairingEpoch: UInt64
    public let revocationEpoch: UInt64
    public let lastAcceptedSequence: UInt64
    public let pairedAt: Date
    public let lastSeenAt: Date?

    public init(
        id: UUID,
        publicKey: Data,
        capabilities: GuardianRemoteCapabilities,
        status: GuardianRemoteDeviceStatus,
        pairingEpoch: UInt64,
        revocationEpoch: UInt64,
        lastAcceptedSequence: UInt64,
        pairedAt: Date,
        lastSeenAt: Date?
    ) {
        self.id = id
        self.publicKey = publicKey
        self.capabilities = capabilities
        self.status = status
        self.pairingEpoch = pairingEpoch
        self.revocationEpoch = revocationEpoch
        self.lastAcceptedSequence = lastAcceptedSequence
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

public enum GuardianRemoteAction: String, Codable, Equatable, Sendable {
    case observe
    case prompt
    case steer
    case interrupt
    case approve
    case deny
    case repair
    case hardRecover
    case cancelRecovery
    case readFiles
    case openTerminal
}

public struct GuardianRemoteCommand: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianRemoteProtocolVersion
    public let commandID: UUID
    public let deviceID: UUID
    public let expectedGeneration: Int64
    public let sequence: UInt64
    public let nonce: UUID
    public let issuedAt: Date
    public let deadline: Date
    public let revocationEpoch: UInt64
    public let targetThreadID: String
    public let action: GuardianRemoteAction
    public let force: Bool
    public let payloadDigest: Data

    public init(
        protocolVersion: GuardianRemoteProtocolVersion,
        commandID: UUID,
        deviceID: UUID,
        expectedGeneration: Int64,
        sequence: UInt64,
        nonce: UUID,
        issuedAt: Date,
        deadline: Date,
        revocationEpoch: UInt64,
        targetThreadID: String,
        action: GuardianRemoteAction,
        force: Bool,
        payloadDigest: Data
    ) {
        self.protocolVersion = protocolVersion
        self.commandID = commandID
        self.deviceID = deviceID
        self.expectedGeneration = expectedGeneration
        self.sequence = sequence
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.deadline = deadline
        self.revocationEpoch = revocationEpoch
        self.targetThreadID = targetThreadID
        self.action = action
        self.force = force
        self.payloadDigest = payloadDigest
    }
}

public struct GuardianRemoteObserveRequest: Codable, Equatable, Sendable {
    public let cursor: GuardianIPCEventCursor?
    public let maximumEvents: Int
    public let acknowledgedCommandIDs: [UUID]

    public init(
        cursor: GuardianIPCEventCursor?,
        maximumEvents: Int = 100,
        acknowledgedCommandIDs: [UUID] = []
    ) {
        self.cursor = cursor
        self.maximumEvents = maximumEvents
        self.acknowledgedCommandIDs = acknowledgedCommandIDs
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case maximumEvents
        case acknowledgedCommandIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decodeIfPresent(
            GuardianIPCEventCursor.self,
            forKey: .cursor
        )
        maximumEvents = try container.decode(Int.self, forKey: .maximumEvents)
        acknowledgedCommandIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .acknowledgedCommandIDs
        ) ?? []
    }

    public var isValid: Bool {
        (1...1_000).contains(maximumEvents)
            && (cursor.map { $0.generation > 0 && $0.lastSequence >= 0 } ?? true)
            && acknowledgedCommandIDs.count <= 100
            && Set(acknowledgedCommandIDs).count == acknowledgedCommandIDs.count
    }
}

public enum GuardianRemoteCommandRejection: Codable, Equatable, Sendable {
    case unsupportedProtocol(GuardianRemoteProtocolVersion)
    case deviceIdentityMismatch
    case deviceRevoked
    case staleRevocationEpoch(expected: UInt64, received: UInt64)
    case commandExpired
    case invalidCommand
    case replayedNonce
    case staleSequence(expected: UInt64, received: UInt64)
    case missingCapability(GuardianRemoteCapabilities)
    case remoteForceForbidden
    case commandIDConflict
}

public enum GuardianRemoteSnapshotReason: Codable, Equatable, Sendable {
    case generationChanged(expected: Int64, current: Int64)
    case sequenceGap(expected: UInt64, received: UInt64)
    case sessionAwaitingSnapshot
    case unknownSession
}

public enum GuardianRemoteCommandValidation: Codable, Equatable, Sendable {
    case accepted
    case rejected(GuardianRemoteCommandRejection)
    case snapshotRequired(GuardianRemoteSnapshotReason)
}

public struct GuardianRemoteCommandValidator: Sendable {
    public init() {}

    public func validate(
        _ command: GuardianRemoteCommand,
        device: GuardianRemoteDevice,
        currentGeneration: Int64,
        consumedNonces: Set<UUID>,
        now: Date
    ) -> GuardianRemoteCommandValidation {
        guard command.protocolVersion == .current else {
            return .rejected(.unsupportedProtocol(command.protocolVersion))
        }
        guard command.deviceID == device.id else {
            return .rejected(.deviceIdentityMismatch)
        }
        guard device.status == .active else {
            return .rejected(.deviceRevoked)
        }
        guard command.revocationEpoch == device.revocationEpoch else {
            return .rejected(.staleRevocationEpoch(
                expected: device.revocationEpoch,
                received: command.revocationEpoch
            ))
        }
        guard command.deadline > now else {
            return .rejected(.commandExpired)
        }
        guard command.issuedAt <= now.addingTimeInterval(30),
              command.deadline > command.issuedAt,
              !command.targetThreadID.isEmpty,
              command.payloadDigest.count == 32 else {
            return .rejected(.invalidCommand)
        }
        guard !command.force else {
            return .rejected(.remoteForceForbidden)
        }
        let generationMatches = command.expectedGeneration == currentGeneration
            || (command.action == .observe && command.expectedGeneration == 0)
        guard generationMatches else {
            return .snapshotRequired(.generationChanged(
                expected: command.expectedGeneration,
                current: currentGeneration
            ))
        }

        let expectedSequence = device.lastAcceptedSequence + 1
        if command.sequence > expectedSequence {
            return .snapshotRequired(.sequenceGap(
                expected: expectedSequence,
                received: command.sequence
            ))
        }
        guard command.sequence == expectedSequence else {
            return .rejected(.staleSequence(
                expected: expectedSequence,
                received: command.sequence
            ))
        }
        guard !consumedNonces.contains(command.nonce) else {
            return .rejected(.replayedNonce)
        }
        let required = requiredCapability(for: command.action)
        guard device.capabilities.contains(required) else {
            return .rejected(.missingCapability(required))
        }
        return .accepted
    }

    private func requiredCapability(
        for action: GuardianRemoteAction
    ) -> GuardianRemoteCapabilities {
        switch action {
        case .observe:
            return .observe
        case .prompt, .steer, .interrupt:
            return .prompt
        case .approve, .deny:
            return .approve
        case .repair:
            return .repair
        case .hardRecover, .cancelRecovery:
            return .policyRecovery
        case .readFiles:
            return .files
        case .openTerminal:
            return .terminal
        }
    }
}

public struct GuardianRemoteReceipt: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let deviceID: UUID
    public let payloadDigest: Data
    public let generation: Int64
    public let sequence: UInt64
    public let acceptedAt: Date

    public init(
        commandID: UUID,
        deviceID: UUID,
        payloadDigest: Data,
        generation: Int64,
        sequence: UInt64,
        acceptedAt: Date
    ) {
        self.commandID = commandID
        self.deviceID = deviceID
        self.payloadDigest = payloadDigest
        self.generation = generation
        self.sequence = sequence
        self.acceptedAt = acceptedAt
    }
}

public struct GuardianRemoteEventBatch: Codable, Equatable, Sendable {
    public let receipt: GuardianRemoteReceipt
    public let acknowledgements: [GuardianRemoteOutcomeAcknowledgement]
    public let commandHistory: GuardianRemoteCommandHistoryPage?
    public let events: [GuardianIPCEvent]
    public let nextCursor: GuardianIPCEventCursor

    public init(
        receipt: GuardianRemoteReceipt,
        acknowledgements: [GuardianRemoteOutcomeAcknowledgement] = [],
        commandHistory: GuardianRemoteCommandHistoryPage? = nil,
        events: [GuardianIPCEvent],
        nextCursor: GuardianIPCEventCursor
    ) {
        self.receipt = receipt
        self.acknowledgements = acknowledgements
        self.commandHistory = commandHistory
        self.events = events
        self.nextCursor = nextCursor
    }
}

public enum GuardianRemoteCommandFailureCode: String, Codable, Equatable, Sendable {
    case adapterUnavailable
    case capabilityUnavailable
    case deadlineExceeded
    case targetUnavailable
    case policyDenied
    case executionFailed
    case payloadUnavailable
    case generationChanged
    case ambiguousEffect
}

public enum GuardianRemoteCommandOutcomeState: Codable, Equatable, Sendable {
    case pending
    case applied(at: Date)
    case failed(code: GuardianRemoteCommandFailureCode, at: Date)
    case indeterminate(code: GuardianRemoteCommandFailureCode, at: Date)
}

public enum GuardianRemoteCommandCompletion: Equatable, Sendable {
    case applied
    case failed(GuardianRemoteCommandFailureCode)
    case indeterminate(GuardianRemoteCommandFailureCode)
}

public struct GuardianRemoteCommandOutcome: Codable, Equatable, Sendable {
    public let receipt: GuardianRemoteReceipt
    public let state: GuardianRemoteCommandOutcomeState

    public init(
        receipt: GuardianRemoteReceipt,
        state: GuardianRemoteCommandOutcomeState
    ) {
        self.receipt = receipt
        self.state = state
    }
}

public struct GuardianRemoteCommandHistoryItem: Codable, Equatable, Sendable {
    public let action: GuardianRemoteAction
    public let targetThreadID: String
    public let expectedGeneration: Int64
    public let issuedAt: Date
    public let deadline: Date
    public let outcome: GuardianRemoteCommandOutcome
    public let outcomeVersion: Int64
    public let updatedAt: Date

    public init(
        action: GuardianRemoteAction,
        targetThreadID: String,
        expectedGeneration: Int64,
        issuedAt: Date,
        deadline: Date,
        outcome: GuardianRemoteCommandOutcome,
        outcomeVersion: Int64,
        updatedAt: Date
    ) {
        self.action = action
        self.targetThreadID = targetThreadID
        self.expectedGeneration = expectedGeneration
        self.issuedAt = issuedAt
        self.deadline = deadline
        self.outcome = outcome
        self.outcomeVersion = outcomeVersion
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        let receipt = outcome.receipt
        guard action != .observe,
              !targetThreadID.isEmpty,
              targetThreadID.utf8.count <= 1_024,
              expectedGeneration > 0,
              expectedGeneration == receipt.generation,
              issuedAt.timeIntervalSince1970.isFinite,
              deadline.timeIntervalSince1970.isFinite,
              deadline > issuedAt,
              issuedAt <= receipt.acceptedAt.addingTimeInterval(30),
              deadline > receipt.acceptedAt,
              receipt.payloadDigest.count == 32,
              receipt.generation > 0,
              receipt.sequence > 0,
              receipt.acceptedAt.timeIntervalSince1970.isFinite,
              outcomeVersion > 0,
              updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= receipt.acceptedAt else {
            return false
        }
        switch outcome.state {
        case .pending:
            return outcomeVersion == 1 && updatedAt == receipt.acceptedAt
        case let .applied(at), let .failed(_, at), let .indeterminate(_, at):
            return outcomeVersion > 1
                && at.timeIntervalSince1970.isFinite
                && at >= receipt.acceptedAt
                && updatedAt == at
        }
    }
}

public enum GuardianRemoteCommandHistoryCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case truncated
}

public struct GuardianRemoteCommandHistoryPage: Codable, Equatable, Sendable {
    public static let maximumItems = 100

    public let items: [GuardianRemoteCommandHistoryItem]
    public let totalCount: Int
    public let completeness: GuardianRemoteCommandHistoryCompleteness

    public init(
        items: [GuardianRemoteCommandHistoryItem],
        totalCount: Int,
        completeness: GuardianRemoteCommandHistoryCompleteness
    ) {
        self.items = items
        self.totalCount = totalCount
        self.completeness = completeness
    }

    public func isValid(for deviceID: UUID) -> Bool {
        guard items.count <= Self.maximumItems,
              totalCount >= items.count,
              Set(items.map { $0.outcome.receipt.commandID }).count == items.count,
              items.allSatisfy({
                  $0.isValid && $0.outcome.receipt.deviceID == deviceID
              }),
              Self.isCanonical(items) else {
            return false
        }
        switch completeness {
        case .complete:
            return totalCount == items.count
        case .truncated:
            return totalCount > items.count
                && items.count == Self.maximumItems
        }
    }

    private static func isCanonical(
        _ items: [GuardianRemoteCommandHistoryItem]
    ) -> Bool {
        zip(items, items.dropFirst()).allSatisfy { newer, older in
            let newerReceipt = newer.outcome.receipt
            let olderReceipt = older.outcome.receipt
            if newerReceipt.acceptedAt == olderReceipt.acceptedAt {
                return newerReceipt.commandID.uuidString > olderReceipt.commandID.uuidString
            }
            return newerReceipt.acceptedAt > olderReceipt.acceptedAt
        }
    }
}

public struct GuardianRemoteOutcomeAcknowledgement: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let deviceID: UUID
    public let outcomeVersion: Int64
    public let acknowledgedAt: Date

    public init(
        commandID: UUID,
        deviceID: UUID,
        outcomeVersion: Int64,
        acknowledgedAt: Date
    ) {
        self.commandID = commandID
        self.deviceID = deviceID
        self.outcomeVersion = outcomeVersion
        self.acknowledgedAt = acknowledgedAt
    }
}

public enum GuardianRemoteAuditKind: String, Codable, Equatable, Sendable {
    case pairingIssued
    case pairingRejected
    case devicePaired
    case deviceRevoked
    case commandAccepted
    case commandRejected
    case commandApplied
    case commandFailed
    case commandIndeterminate
    case commandOutcomeAcknowledged
}

public enum GuardianPairingAuditRejection: String, Codable, Equatable, Sendable {
    case invitationUnsupportedProtocol = "pairing.rejected.invitation.unsupported_protocol"
    case invitationInvalidPayload = "pairing.rejected.invitation.invalid_payload"
    case invitationIdentityMismatch = "pairing.rejected.invitation.identity_mismatch"
    case invitationExpired = "pairing.rejected.invitation.expired"
    case invitationAlreadyConsumed = "pairing.rejected.invitation.already_consumed"
    case invitationInvalidSignature = "pairing.rejected.invitation.invalid_signature"
    case claimUnsupportedProtocol = "pairing.rejected.claim.unsupported_protocol"
    case claimInvalid = "pairing.rejected.claim.invalid_claim"
    case claimInvitationMismatch = "pairing.rejected.claim.invitation_mismatch"
    case claimExpired = "pairing.rejected.claim.expired"
    case claimCapabilityEscalation = "pairing.rejected.claim.capability_escalation"
    case claimInvalidPublicKey = "pairing.rejected.claim.invalid_public_key"
    case claimInvalidSignature = "pairing.rejected.claim.invalid_signature"
}

public enum GuardianRemoteCommandAuditRejection: String, Codable, Equatable, Sendable {
    case unknownDevice = "command.rejected.unknown_device"
    case payloadTooLarge = "command.rejected.payload_too_large"
    case payloadDigestMismatch = "command.rejected.payload_digest_mismatch"
    case invalidPayload = "command.rejected.invalid_payload"
    case payloadProtectionUnavailable = "command.rejected.payload_protection_unavailable"
    case adapterUnavailable = "command.rejected.adapter_unavailable"
    case deviceIdentityMismatch = "command.rejected.device_identity_mismatch"
    case invalidPublicKey = "command.rejected.invalid_public_key"
    case invalidSignature = "command.rejected.invalid_signature"
    case unsupportedProtocol = "command.rejected.unsupported_protocol"
    case deviceRevoked = "command.rejected.device_revoked"
    case staleRevocationEpoch = "command.rejected.stale_revocation_epoch"
    case commandExpired = "command.rejected.command_expired"
    case invalidCommand = "command.rejected.invalid_command"
    case replayedNonce = "command.rejected.replayed_nonce"
    case staleSequence = "command.rejected.stale_sequence"
    case missingCapability = "command.rejected.missing_capability"
    case remoteForceForbidden = "command.rejected.remote_force_forbidden"
    case commandIDConflict = "command.rejected.command_id_conflict"
    case generationChanged = "command.rejected.generation_changed"
    case sequenceGap = "command.rejected.sequence_gap"
    case sessionAwaitingSnapshot = "command.rejected.session_awaiting_snapshot"
    case unknownSession = "command.rejected.unknown_session"
}

public struct GuardianRemoteAuditEvent: Codable, Equatable, Sendable {
    public let index: Int64
    public let kind: GuardianRemoteAuditKind
    public let deviceID: UUID?
    public let commandID: UUID?
    public let reason: String
    public let generation: Int64?
    public let sequence: UInt64?
    public let occurredAt: Date

    public init(
        index: Int64,
        kind: GuardianRemoteAuditKind,
        deviceID: UUID?,
        commandID: UUID?,
        reason: String,
        generation: Int64?,
        sequence: UInt64?,
        occurredAt: Date
    ) {
        self.index = index
        self.kind = kind
        self.deviceID = deviceID
        self.commandID = commandID
        self.reason = reason
        self.generation = generation
        self.sequence = sequence
        self.occurredAt = occurredAt
    }
}

public enum GuardianRemoteReconciliation: Codable, Equatable, Sendable {
    case accepted(GuardianRemoteReceipt)
    case duplicate(GuardianRemoteReceipt)
    case rejected(GuardianRemoteCommandRejection)
    case snapshotRequired(GuardianRemoteSnapshotReason)
}

public actor GuardianRemoteCommandLedger {
    private var commandsByID: [UUID: GuardianRemoteCommand] = [:]
    private var receiptsByID: [UUID: GuardianRemoteReceipt] = [:]
    private var consumedNonces: Set<UUID> = []

    public init() {}

    public var acceptanceCount: Int { receiptsByID.count }

    public func reconcile(
        _ command: GuardianRemoteCommand,
        device: GuardianRemoteDevice,
        currentGeneration: Int64,
        now: Date
    ) -> GuardianRemoteReconciliation {
        if let existing = commandsByID[command.commandID],
           let receipt = receiptsByID[command.commandID] {
            return existing == command
                ? .duplicate(receipt)
                : .rejected(.commandIDConflict)
        }

        switch GuardianRemoteCommandValidator().validate(
            command,
            device: device,
            currentGeneration: currentGeneration,
            consumedNonces: consumedNonces,
            now: now
        ) {
        case .accepted:
            let receipt = GuardianRemoteReceipt(
                commandID: command.commandID,
                deviceID: command.deviceID,
                payloadDigest: command.payloadDigest,
                generation: currentGeneration,
                sequence: command.sequence,
                acceptedAt: now
            )
            commandsByID[command.commandID] = command
            receiptsByID[command.commandID] = receipt
            consumedNonces.insert(command.nonce)
            return .accepted(receipt)
        case let .rejected(reason):
            return .rejected(reason)
        case let .snapshotRequired(reason):
            return .snapshotRequired(reason)
        }
    }
}

public struct GuardianPairingChallenge: Codable, Equatable, Sendable {
    public let nonce: UUID
    public let guardianIdentityHash: Data
    public let expiresAt: Date
    public let consumedAt: Date?

    public init(
        nonce: UUID,
        guardianIdentityHash: Data,
        expiresAt: Date,
        consumedAt: Date?
    ) {
        self.nonce = nonce
        self.guardianIdentityHash = guardianIdentityHash
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
    }
}

public enum GuardianPairingRejection: Codable, Equatable, Sendable {
    case invalidChallenge
    case identityMismatch
    case expired
    case alreadyConsumed
}

public enum GuardianPairingValidation: Codable, Equatable, Sendable {
    case accepted
    case rejected(GuardianPairingRejection)
}

public struct GuardianPairingPolicy: Sendable {
    public init() {}

    public func validate(
        _ challenge: GuardianPairingChallenge,
        expectedGuardianIdentityHash: Data,
        now: Date
    ) -> GuardianPairingValidation {
        guard challenge.guardianIdentityHash.count == SHA256.byteCount,
              expectedGuardianIdentityHash.count == SHA256.byteCount else {
            return .rejected(.invalidChallenge)
        }
        guard challenge.guardianIdentityHash == expectedGuardianIdentityHash else {
            return .rejected(.identityMismatch)
        }
        guard challenge.expiresAt > now else {
            return .rejected(.expired)
        }
        guard challenge.consumedAt == nil else {
            return .rejected(.alreadyConsumed)
        }
        return .accepted
    }
}

public struct GuardianRemoteSessionCursor: Codable, Equatable, Sendable {
    public let generation: Int64
    public let lastSequence: UInt64

    public init(generation: Int64, lastSequence: UInt64) {
        self.generation = generation
        self.lastSequence = lastSequence
    }
}

public struct GuardianRemoteEvent: Codable, Equatable, Sendable {
    public let generation: Int64
    public let sequence: UInt64

    public init(generation: Int64, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }
}

public enum GuardianRemoteEventAssessment: Codable, Equatable, Sendable {
    case accepted
    case snapshotRequired(GuardianRemoteSnapshotReason)
}

public actor GuardianRemoteSessionHub {
    private struct Session: Sendable {
        let deviceID: UUID
        var cursor: GuardianRemoteSessionCursor
        var awaitingSnapshot: Bool
    }

    private var sessions: [UUID: Session] = [:]
    private var revokedDeviceIDs: Set<UUID> = []

    public init() {}

    @discardableResult
    public func open(
        sessionID: UUID,
        device: GuardianRemoteDevice,
        cursor: GuardianRemoteSessionCursor
    ) -> Bool {
        guard device.status == .active,
              !revokedDeviceIDs.contains(device.id),
              sessions[sessionID] == nil else {
            return false
        }
        sessions[sessionID] = Session(
            deviceID: device.id,
            cursor: cursor,
            awaitingSnapshot: false
        )
        return true
    }

    public func close(sessionID: UUID) {
        sessions.removeValue(forKey: sessionID)
    }

    public func revoke(deviceID: UUID, at _: Date) -> [UUID] {
        revokedDeviceIDs.insert(deviceID)
        let closed = sessions.compactMap { sessionID, session in
            session.deviceID == deviceID ? sessionID : nil
        }
        for sessionID in closed {
            sessions.removeValue(forKey: sessionID)
        }
        return closed.sorted { $0.uuidString < $1.uuidString }
    }

    public func activeSessionCount(deviceID: UUID) -> Int {
        sessions.values.reduce(into: 0) { count, session in
            if session.deviceID == deviceID { count += 1 }
        }
    }

    public func receive(
        _ event: GuardianRemoteEvent,
        sessionID: UUID
    ) -> GuardianRemoteEventAssessment {
        guard var session = sessions[sessionID] else {
            return .snapshotRequired(.unknownSession)
        }
        guard !session.awaitingSnapshot else {
            return .snapshotRequired(.sessionAwaitingSnapshot)
        }
        guard event.generation == session.cursor.generation else {
            session.awaitingSnapshot = true
            sessions[sessionID] = session
            return .snapshotRequired(.generationChanged(
                expected: session.cursor.generation,
                current: event.generation
            ))
        }
        let expected = session.cursor.lastSequence + 1
        guard event.sequence == expected else {
            session.awaitingSnapshot = true
            sessions[sessionID] = session
            return .snapshotRequired(.sequenceGap(
                expected: expected,
                received: event.sequence
            ))
        }
        session.cursor = GuardianRemoteSessionCursor(
            generation: event.generation,
            lastSequence: event.sequence
        )
        sessions[sessionID] = session
        return .accepted
    }

    public func applySnapshot(
        _ cursor: GuardianRemoteSessionCursor,
        sessionID: UUID
    ) {
        guard var session = sessions[sessionID] else { return }
        session.cursor = cursor
        session.awaitingSnapshot = false
        sessions[sessionID] = session
    }
}
