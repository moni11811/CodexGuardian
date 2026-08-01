import Foundation

public enum PhoneRemoteSessionError: Error, Equatable, Sendable {
    case invalidRecord
    case pairingMismatch
    case sequenceMismatch
    case commandConflict
    case outcomeMismatch
    case acknowledgementMismatch
}

public struct PhoneRemoteOutcomeAcknowledgement: Codable, Equatable, Sendable {
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

public struct PhoneRemoteSessionRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let guardianID: UUID
    public let deviceID: UUID
    public let pairingEpoch: UInt64
    public let revocationEpoch: UInt64
    public private(set) var cursor: ProjectionCursor?
    public private(set) var nextSequence: UInt64
    public private(set) var pendingRequests: [PhonePendingRemoteRequest]
    public private(set) var commandHistory: [PhoneRemoteCommandOutcome]
    public private(set) var commandHistoryPage: PhoneRemoteCommandHistoryPage?
    public private(set) var pendingAcknowledgementIDs: [UUID]
    public private(set) var updatedAt: Date

    public var reconciledCommandHistory: PhoneRemoteCommandHistoryPage {
        commandHistoryPage ?? .unavailable
    }

    public init(
        version: Int = Self.currentVersion,
        guardianID: UUID,
        deviceID: UUID,
        pairingEpoch: UInt64,
        revocationEpoch: UInt64,
        cursor: ProjectionCursor?,
        nextSequence: UInt64,
        pendingRequests: [PhonePendingRemoteRequest],
        commandHistory: [PhoneRemoteCommandOutcome],
        pendingAcknowledgementIDs: [UUID],
        updatedAt: Date,
        commandHistoryPage: PhoneRemoteCommandHistoryPage? = nil
    ) {
        self.version = version
        self.guardianID = guardianID
        self.deviceID = deviceID
        self.pairingEpoch = pairingEpoch
        self.revocationEpoch = revocationEpoch
        self.cursor = cursor
        self.nextSequence = nextSequence
        self.pendingRequests = pendingRequests
        self.commandHistory = commandHistory
        self.commandHistoryPage = commandHistoryPage
        self.pendingAcknowledgementIDs = pendingAcknowledgementIDs
        self.updatedAt = updatedAt
    }

    public static func fresh(
        for pairing: PhonePairedGuardian,
        now: Date = Date()
    ) -> PhoneRemoteSessionRecord {
        PhoneRemoteSessionRecord(
            guardianID: pairing.guardianID,
            deviceID: pairing.deviceID,
            pairingEpoch: pairing.pairingEpoch,
            revocationEpoch: pairing.revocationEpoch,
            cursor: nil,
            nextSequence: 1,
            pendingRequests: [],
            commandHistory: [],
            pendingAcknowledgementIDs: [],
            updatedAt: now,
            commandHistoryPage: .unavailable
        )
    }

    public mutating func enqueue(
        _ request: PhonePendingRemoteRequest,
        now: Date = Date()
    ) throws {
        guard request.isValid,
              request.deviceID == deviceID,
              request.sequence == nextSequence,
              request.expectedGeneration > 0 || request.action == .observe,
              nextSequence < UInt64.max,
              now.timeIntervalSince1970.isFinite else {
            throw PhoneRemoteSessionError.sequenceMismatch
        }
        guard !pendingRequests.contains(where: {
            $0.requestID == request.requestID
                || $0.commandID == request.commandID
                || $0.nonce == request.nonce
        }), !commandHistory.contains(where: { $0.commandID == request.commandID }) else {
            throw PhoneRemoteSessionError.commandConflict
        }
        pendingRequests.append(request)
        nextSequence += 1
        updatedAt = now
    }

    public mutating func updateCursor(
        _ cursor: ProjectionCursor,
        now: Date = Date()
    ) throws {
        guard cursor.generation > 0,
              now.timeIntervalSince1970.isFinite else {
            throw PhoneRemoteSessionError.invalidRecord
        }
        self.cursor = cursor
        updatedAt = now
    }

    public mutating func requireAuthoritativeSnapshot(
        now: Date = Date()
    ) throws {
        guard now.timeIntervalSince1970.isFinite else {
            throw PhoneRemoteSessionError.invalidRecord
        }
        cursor = nil
        updatedAt = now
    }

    public mutating func record(
        _ outcome: PhoneRemoteCommandOutcome,
        now: Date = Date()
    ) throws {
        guard let pending = pendingRequests.first(where: {
            $0.commandID == outcome.commandID
        }), pending.deviceID == outcome.deviceID,
              pending.payloadDigest == outcome.payloadDigest,
              pending.sequence == outcome.sequence,
              outcome.generation > 0,
              now.timeIntervalSince1970.isFinite else {
            throw PhoneRemoteSessionError.outcomeMismatch
        }
        pendingRequests.removeAll { $0.commandID == outcome.commandID }
        commandHistory.removeAll { $0.commandID == outcome.commandID }
        commandHistory.append(outcome)
        if pending.action != .observe {
            try recordDetailedHistory(pending: pending, outcome: outcome)
        }
        if Self.isTerminal(outcome.state),
           !pendingAcknowledgementIDs.contains(outcome.commandID) {
            pendingAcknowledgementIDs.append(outcome.commandID)
        }
        updatedAt = now
    }

    public mutating func mergeCommandHistory(
        _ page: PhoneRemoteCommandHistoryPage,
        now: Date = Date()
    ) throws {
        guard page.isValid(for: deviceID),
              now.timeIntervalSince1970.isFinite else {
            throw PhoneRemoteSessionError.outcomeMismatch
        }
        guard page.completeness != .unavailable else {
            updatedAt = now
            return
        }
        let existing = commandHistoryPage?.items ?? []
        let remoteIDs = Set(page.items.map { $0.outcome.commandID })
        var byID = Dictionary(uniqueKeysWithValues: existing.map {
            ($0.outcome.commandID, $0)
        })
        for incoming in page.items {
            guard let current = byID[incoming.outcome.commandID] else {
                byID[incoming.outcome.commandID] = incoming
                continue
            }
            guard Self.sameCommand(current, incoming) else {
                throw PhoneRemoteSessionError.outcomeMismatch
            }
            if incoming.outcomeVersion < current.outcomeVersion {
                continue
            }
            if incoming.outcomeVersion == current.outcomeVersion {
                guard incoming == current else {
                    throw PhoneRemoteSessionError.outcomeMismatch
                }
                continue
            }
            guard Self.canAdvance(from: current.outcome.state, to: incoming.outcome.state) else {
                throw PhoneRemoteSessionError.outcomeMismatch
            }
            byID[incoming.outcome.commandID] = incoming
        }
        let unmatchedLocal = Set(existing.map { $0.outcome.commandID })
            .subtracting(remoteIDs)
        var merged = byID.values.sorted(by: Self.newestCommandFirst)
        let mergedTotal = max(page.totalCount, merged.count)
        if merged.count > PhoneRemoteCommandHistoryPage.maximumItems {
            merged = Array(merged.prefix(PhoneRemoteCommandHistoryPage.maximumItems))
        }
        let completeness: PhoneRemoteCommandHistoryCompleteness
        if !unmatchedLocal.isEmpty {
            completeness = .unavailable
        } else if mergedTotal > merged.count {
            completeness = .truncated
        } else {
            completeness = page.completeness
        }
        commandHistoryPage = PhoneRemoteCommandHistoryPage(
            items: merged,
            totalCount: mergedTotal,
            completeness: completeness
        )
        guard commandHistoryPage?.isValid(for: deviceID) == true else {
            throw PhoneRemoteSessionError.outcomeMismatch
        }
        updatedAt = now
    }

    public mutating func applyAcknowledgements(
        _ acknowledgements: [PhoneRemoteOutcomeAcknowledgement],
        now: Date = Date()
    ) throws {
        guard now.timeIntervalSince1970.isFinite else {
            throw PhoneRemoteSessionError.acknowledgementMismatch
        }
        for acknowledgement in acknowledgements {
            guard acknowledgement.deviceID == deviceID,
                  acknowledgement.outcomeVersion > 0,
                  acknowledgement.acknowledgedAt.timeIntervalSince1970.isFinite,
                  pendingAcknowledgementIDs.contains(acknowledgement.commandID) else {
                throw PhoneRemoteSessionError.acknowledgementMismatch
            }
        }
        let acknowledged = Set(acknowledgements.map(\.commandID))
        pendingAcknowledgementIDs.removeAll { acknowledged.contains($0) }
        updatedAt = now
    }

    public func isValid(for pairing: PhonePairedGuardian) -> Bool {
        guard version == Self.currentVersion,
              guardianID == pairing.guardianID,
              deviceID == pairing.deviceID,
              pairingEpoch == pairing.pairingEpoch,
              revocationEpoch == pairing.revocationEpoch,
              nextSequence > 0,
              updatedAt.timeIntervalSince1970.isFinite,
              cursor.map({ $0.generation > 0 }) ?? true else {
            return false
        }
        guard Set(pendingRequests.map(\.requestID)).count == pendingRequests.count,
              Set(pendingRequests.map(\.commandID)).count == pendingRequests.count,
              Set(pendingRequests.map(\.nonce)).count == pendingRequests.count,
              pendingRequests.allSatisfy({
                $0.isValid && $0.deviceID == deviceID && $0.sequence < nextSequence
              }),
              Set(commandHistory.map(\.commandID)).count == commandHistory.count,
              commandHistory.allSatisfy({
                $0.deviceID == deviceID
                    && $0.payloadDigest.count == 32
                    && $0.generation > 0
                    && $0.sequence > 0
                    && $0.acceptedAt.timeIntervalSince1970.isFinite
              }),
              commandHistoryPage?.isValid(for: deviceID) ?? true,
              Set(pendingAcknowledgementIDs).count == pendingAcknowledgementIDs.count else {
            return false
        }
        let terminalIDs = Set(commandHistory.compactMap {
            Self.isTerminal($0.state) ? $0.commandID : nil
        })
        return Set(pendingAcknowledgementIDs).isSubset(of: terminalIDs)
    }

    private static func isTerminal(_ state: PhoneCommandState) -> Bool {
        switch state {
        case .applied, .failed, .indeterminate:
            true
        case .pending, .accepted:
            false
        }
    }

    private mutating func recordDetailedHistory(
        pending: PhonePendingRemoteRequest,
        outcome: PhoneRemoteCommandOutcome
    ) throws {
        let version: Int64
        let updatedAt: Date
        switch outcome.state {
        case .pending:
            throw PhoneRemoteSessionError.outcomeMismatch
        case .accepted:
            version = 1
            updatedAt = outcome.acceptedAt
        case let .applied(at), let .failed(_, at), let .indeterminate(_, at):
            version = 2
            updatedAt = at
        }
        let item = PhoneRemoteCommandHistoryItem(
            action: PhoneRemoteCommandAction(phoneAction: pending.action),
            targetThreadID: pending.targetThreadID,
            expectedGeneration: pending.expectedGeneration,
            issuedAt: pending.issuedAt,
            deadline: pending.deadline,
            outcome: outcome,
            outcomeVersion: version,
            updatedAt: updatedAt
        )
        guard item.isValid else {
            throw PhoneRemoteSessionError.outcomeMismatch
        }
        var items = commandHistoryPage?.items ?? []
        items.removeAll { $0.outcome.commandID == item.outcome.commandID }
        items.append(item)
        items.sort(by: Self.newestCommandFirst)
        if items.count > PhoneRemoteCommandHistoryPage.maximumItems {
            items = Array(items.prefix(PhoneRemoteCommandHistoryPage.maximumItems))
        }
        commandHistoryPage = PhoneRemoteCommandHistoryPage(
            items: items,
            totalCount: max(commandHistoryPage?.totalCount ?? 0, items.count),
            completeness: .unavailable
        )
    }

    private static func sameCommand(
        _ left: PhoneRemoteCommandHistoryItem,
        _ right: PhoneRemoteCommandHistoryItem
    ) -> Bool {
        left.action == right.action
            && left.targetThreadID == right.targetThreadID
            && left.expectedGeneration == right.expectedGeneration
            && left.issuedAt == right.issuedAt
            && left.deadline == right.deadline
            && left.outcome.commandID == right.outcome.commandID
            && left.outcome.deviceID == right.outcome.deviceID
            && left.outcome.payloadDigest == right.outcome.payloadDigest
            && left.outcome.generation == right.outcome.generation
            && left.outcome.sequence == right.outcome.sequence
            && left.outcome.acceptedAt == right.outcome.acceptedAt
    }

    private static func canAdvance(
        from current: PhoneCommandState,
        to incoming: PhoneCommandState
    ) -> Bool {
        guard current == .accepted else { return false }
        switch incoming {
        case .applied, .failed, .indeterminate:
            return true
        case .pending, .accepted:
            return false
        }
    }

    private static func newestCommandFirst(
        _ left: PhoneRemoteCommandHistoryItem,
        _ right: PhoneRemoteCommandHistoryItem
    ) -> Bool {
        if left.outcome.acceptedAt == right.outcome.acceptedAt {
            return left.outcome.commandID.uuidString > right.outcome.commandID.uuidString
        }
        return left.outcome.acceptedAt > right.outcome.acceptedAt
    }
}

public actor PhoneKeychainRemoteSessionStorage {
    public static let account = "remote-session-v1"

    private let backend: any PhoneSecureStorage

    public init(backend: any PhoneSecureStorage = PhoneKeychainSecureStorage()) {
        self.backend = backend
    }

    public func load(
        for pairing: PhonePairedGuardian
    ) async throws -> PhoneRemoteSessionRecord? {
        guard let data = try backend.read(account: Self.account) else { return nil }
        let record: PhoneRemoteSessionRecord
        do {
            record = try decoder().decode(PhoneRemoteSessionRecord.self, from: data)
        } catch {
            throw PhoneSecureStorageError.invalidData
        }
        guard record.isValid(for: pairing) else {
            throw PhoneSecureStorageError.invalidData
        }
        return record
    }

    public func save(
        _ record: PhoneRemoteSessionRecord,
        for pairing: PhonePairedGuardian
    ) async throws {
        guard record.isValid(for: pairing) else {
            throw PhoneSecureStorageError.invalidData
        }
        do {
            try backend.write(
                try encoder().encode(record),
                account: Self.account
            )
        } catch let error as PhoneSecureStorageError {
            throw error
        } catch {
            throw PhoneSecureStorageError.invalidData
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
