import CryptoKit
import Foundation

public enum PhoneRemoteOperationalCodecError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidPairing
    case unauthorizedAction
    case invalidCommand
    case invalidFrame
    case oversizedFrame
    case requestIdentityMismatch
    case commandIdentityMismatch
    case deviceIdentityMismatch
    case payloadDigestMismatch
    case invalidResponse
    case rejected(String)
}

public struct PhonePendingRemoteRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let commandID: UUID
    public let deviceID: UUID
    public let expectedGeneration: Int64
    public let sequence: UInt64
    public let nonce: UUID
    public let targetThreadID: String
    public let action: PhoneAction
    public let payloadDigest: Data
    public let frame: Data
    public let issuedAt: Date
    public let deadline: Date

    public init(
        requestID: UUID,
        commandID: UUID,
        deviceID: UUID,
        expectedGeneration: Int64,
        sequence: UInt64,
        nonce: UUID,
        targetThreadID: String,
        action: PhoneAction,
        payloadDigest: Data,
        frame: Data,
        issuedAt: Date,
        deadline: Date
    ) {
        self.requestID = requestID
        self.commandID = commandID
        self.deviceID = deviceID
        self.expectedGeneration = expectedGeneration
        self.sequence = sequence
        self.nonce = nonce
        self.targetThreadID = targetThreadID
        self.action = action
        self.payloadDigest = payloadDigest
        self.frame = frame
        self.issuedAt = issuedAt
        self.deadline = deadline
    }

    public var isValid: Bool {
        expectedGeneration >= 0
            && sequence > 0
            && !targetThreadID.isEmpty
            && targetThreadID.utf8.count <= 1_024
            && payloadDigest.count == 32
            && frame.count > 4
            && frame.count <= PhoneRemoteOperationalCodec.maximumFrameBytes + 4
            && issuedAt.timeIntervalSince1970.isFinite
            && deadline > issuedAt
    }
}

public struct PhoneRemoteCommandOutcome: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let deviceID: UUID
    public let payloadDigest: Data
    public let generation: Int64
    public let sequence: UInt64
    public let acceptedAt: Date
    public let state: PhoneCommandState

    public init(
        commandID: UUID,
        deviceID: UUID,
        payloadDigest: Data,
        generation: Int64,
        sequence: UInt64,
        acceptedAt: Date,
        state: PhoneCommandState
    ) {
        self.commandID = commandID
        self.deviceID = deviceID
        self.payloadDigest = payloadDigest
        self.generation = generation
        self.sequence = sequence
        self.acceptedAt = acceptedAt
        self.state = state
    }
}

public enum PhoneRemoteCommandAction: String, Codable, Equatable, Sendable {
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

    public init(phoneAction: PhoneAction) {
        switch phoneAction {
        case .observe: self = .observe
        case .promptAgent: self = .prompt
        case .steerAgent: self = .steer
        case .interruptAgent: self = .interrupt
        case .approve: self = .approve
        case .deny: self = .deny
        case .repair: self = .repair
        case .restartAgent: self = .hardRecover
        case .cancelRecovery: self = .cancelRecovery
        case .readFiles: self = .readFiles
        }
    }

    public var phoneAction: PhoneAction? {
        switch self {
        case .observe: .observe
        case .prompt: .promptAgent
        case .steer: .steerAgent
        case .interrupt: .interruptAgent
        case .approve: .approve
        case .deny: .deny
        case .repair: .repair
        case .hardRecover: .restartAgent
        case .cancelRecovery: .cancelRecovery
        case .readFiles: .readFiles
        case .openTerminal: nil
        }
    }
}

public struct PhoneRemoteCommandHistoryItem: Codable, Equatable, Sendable {
    public let action: PhoneRemoteCommandAction
    public let targetThreadID: String
    public let expectedGeneration: Int64
    public let issuedAt: Date
    public let deadline: Date
    public let outcome: PhoneRemoteCommandOutcome
    public let outcomeVersion: Int64
    public let updatedAt: Date

    public init(
        action: PhoneRemoteCommandAction,
        targetThreadID: String,
        expectedGeneration: Int64,
        issuedAt: Date,
        deadline: Date,
        outcome: PhoneRemoteCommandOutcome,
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
        guard action != .observe,
              !targetThreadID.isEmpty,
              targetThreadID.utf8.count <= 1_024,
              expectedGeneration > 0,
              expectedGeneration == outcome.generation,
              issuedAt.timeIntervalSince1970.isFinite,
              deadline.timeIntervalSince1970.isFinite,
              deadline > issuedAt,
              issuedAt <= outcome.acceptedAt.addingTimeInterval(30),
              deadline > outcome.acceptedAt,
              outcome.payloadDigest.count == 32,
              outcome.generation > 0,
              outcome.sequence > 0,
              outcome.acceptedAt.timeIntervalSince1970.isFinite,
              outcomeVersion > 0,
              updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= outcome.acceptedAt else {
            return false
        }
        switch outcome.state {
        case .pending:
            return false
        case .accepted:
            return outcomeVersion == 1 && updatedAt == outcome.acceptedAt
        case let .applied(at), let .failed(_, at), let .indeterminate(_, at):
            return outcomeVersion > 1
                && at.timeIntervalSince1970.isFinite
                && at >= outcome.acceptedAt
                && updatedAt == at
        }
    }
}

public enum PhoneRemoteCommandHistoryCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case truncated
    case unavailable
}

public struct PhoneRemoteCommandHistoryPage: Codable, Equatable, Sendable {
    public static let maximumItems = 100
    public static let unavailable = PhoneRemoteCommandHistoryPage(
        items: [],
        totalCount: 0,
        completeness: .unavailable
    )

    public let items: [PhoneRemoteCommandHistoryItem]
    public let totalCount: Int
    public let completeness: PhoneRemoteCommandHistoryCompleteness

    public init(
        items: [PhoneRemoteCommandHistoryItem],
        totalCount: Int,
        completeness: PhoneRemoteCommandHistoryCompleteness
    ) {
        self.items = items
        self.totalCount = totalCount
        self.completeness = completeness
    }

    public func isValid(for deviceID: UUID) -> Bool {
        guard items.count <= Self.maximumItems,
              totalCount >= items.count,
              Set(items.map { $0.outcome.commandID }).count == items.count,
              Set(items.map { "\($0.outcome.deviceID.uuidString):\($0.outcome.sequence)" }).count
                == items.count,
              items.allSatisfy({
                  $0.isValid && $0.outcome.deviceID == deviceID
              }),
              Self.isCanonical(items) else {
            return false
        }
        switch completeness {
        case .unavailable:
            return true
        case .complete:
            return totalCount == items.count
        case .truncated:
            return totalCount > items.count && items.count == Self.maximumItems
        }
    }

    private static func isCanonical(
        _ items: [PhoneRemoteCommandHistoryItem]
    ) -> Bool {
        zip(items, items.dropFirst()).allSatisfy { newer, older in
            if newer.outcome.acceptedAt == older.outcome.acceptedAt {
                return newer.outcome.commandID.uuidString > older.outcome.commandID.uuidString
            }
            return newer.outcome.acceptedAt > older.outcome.acceptedAt
        }
    }
}

public enum PhoneRemoteTaskState: String, Codable, Equatable, Sendable {
    case working
    case slow
    case finished
    case recovering
    case running
    case idle
    case waitingUser
    case stuck
    case unknown
}

public enum PhoneRemoteInventoryCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case incomplete
    case notApplicable
}

public struct PhoneRemoteTaskSnapshot: Codable, Equatable, Sendable {
    public let threadID: String
    public let state: PhoneRemoteTaskState
    public let reason: String
    public let serverGeneration: Int64
    public let eventSequence: Int64
    public let confidence: Double
    public let expiresAt: Date

    public init(
        threadID: String,
        state: PhoneRemoteTaskState,
        reason: String,
        serverGeneration: Int64,
        eventSequence: Int64,
        confidence: Double,
        expiresAt: Date
    ) {
        self.threadID = threadID
        self.state = state
        self.reason = reason
        self.serverGeneration = serverGeneration
        self.eventSequence = eventSequence
        self.confidence = confidence
        self.expiresAt = expiresAt
    }
}

public enum PhoneRemoteOperationKind: String, Codable, Equatable, Sendable {
    case nativeRecovery
    case hardRestart
}

public enum PhoneRemoteOperationPhase: String, Codable, Equatable, Sendable {
    case prepared
    case gated
    case restartIssued
    case desktopStarted
    case controlReady
    case targetLoaded
    case continuationSent
    case deliveryReceipt
    case monitoring
    case waitingUser
    case acknowledged
    case failed
    case timedOut
    case deadLetter
}

public struct PhoneRemoteOperationSnapshot: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let kind: PhoneRemoteOperationKind
    public let originThreadID: String
    public let phase: PhoneRemoteOperationPhase
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        operationID: UUID,
        kind: PhoneRemoteOperationKind,
        originThreadID: String,
        phase: PhoneRemoteOperationPhase,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.operationID = operationID
        self.kind = kind
        self.originThreadID = originThreadID
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PhoneRemoteOperationHistoryCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case truncated
    case unavailable
}

public struct PhoneRemoteSnapshot: Codable, Equatable, Sendable {
    public let cursor: ProjectionCursor
    public let capturedAt: Date
    public let inventoryCompleteness: PhoneRemoteInventoryCompleteness
    public let tasks: [PhoneRemoteTaskSnapshot]
    public let operationHistory: [PhoneRemoteOperationSnapshot]
    public let operationHistoryCompleteness: PhoneRemoteOperationHistoryCompleteness
    public let operationHistoryTotalCount: Int
    public let commandHistory: PhoneRemoteCommandHistoryPage

    public var operationHistoryIsComplete: Bool {
        operationHistoryCompleteness == .complete
    }

    public init(
        cursor: ProjectionCursor,
        capturedAt: Date,
        inventoryCompleteness: PhoneRemoteInventoryCompleteness,
        tasks: [PhoneRemoteTaskSnapshot],
        operationHistory: [PhoneRemoteOperationSnapshot] = [],
        operationHistoryCompleteness: PhoneRemoteOperationHistoryCompleteness = .unavailable,
        operationHistoryTotalCount: Int? = nil,
        commandHistory: PhoneRemoteCommandHistoryPage = .unavailable
    ) {
        self.cursor = cursor
        self.capturedAt = capturedAt
        self.inventoryCompleteness = inventoryCompleteness
        self.tasks = tasks
        self.operationHistory = operationHistory
        self.operationHistoryCompleteness = operationHistoryCompleteness
        self.operationHistoryTotalCount = operationHistoryTotalCount ?? operationHistory.count
        self.commandHistory = commandHistory
    }

    public func replacingCommandHistory(
        with commandHistory: PhoneRemoteCommandHistoryPage
    ) -> PhoneRemoteSnapshot {
        PhoneRemoteSnapshot(
            cursor: cursor,
            capturedAt: capturedAt,
            inventoryCompleteness: inventoryCompleteness,
            tasks: tasks,
            operationHistory: operationHistory,
            operationHistoryCompleteness: operationHistoryCompleteness,
            operationHistoryTotalCount: operationHistoryTotalCount,
            commandHistory: commandHistory
        )
    }
}

public enum PhoneRemoteObservationPayload: Codable, Equatable, Sendable {
    case snapshot(PhoneRemoteSnapshot)
    case eventsRequireSnapshot(nextCursor: ProjectionCursor)
}

public struct PhoneRemoteObserveResponse: Codable, Equatable, Sendable {
    public let outcome: PhoneRemoteCommandOutcome
    public let acknowledgements: [PhoneRemoteOutcomeAcknowledgement]
    public let commandHistory: PhoneRemoteCommandHistoryPage
    public let payload: PhoneRemoteObservationPayload

    public init(
        outcome: PhoneRemoteCommandOutcome,
        acknowledgements: [PhoneRemoteOutcomeAcknowledgement],
        commandHistory: PhoneRemoteCommandHistoryPage = .unavailable,
        payload: PhoneRemoteObservationPayload
    ) {
        self.outcome = outcome
        self.acknowledgements = acknowledgements
        self.commandHistory = commandHistory
        self.payload = payload
    }
}

public struct PhoneRemoteOperationalCodec: Sendable {
    public static let maximumFrameBytes = 512 * 1_024
    public static let inventoryThreadID = "guardian:inventory"

    public init() {}

    public func makeObserveRequest(
        identity: PhoneDeviceIdentity,
        pairing: PhonePairedGuardian,
        expectedGeneration: Int64,
        sequence: UInt64,
        cursor: ProjectionCursor?,
        acknowledgedCommandIDs: [UUID],
        requestID: UUID = UUID(),
        commandID: UUID = UUID(),
        nonce: UUID = UUID(),
        now: Date = Date(),
        deadline: Date
    ) throws -> PhonePendingRemoteRequest {
        guard identity.isValid else { throw PhoneRemoteOperationalCodecError.invalidIdentity }
        guard pairing.deviceID == identity.deviceID,
              pairing.endpoint.isValid,
              pairing.guardianPublicKey.count == 32,
              pairing.pairingEpoch > 0 else {
            throw PhoneRemoteOperationalCodecError.invalidPairing
        }
        guard pairing.capabilities.contains(.observe) else {
            throw PhoneRemoteOperationalCodecError.unauthorizedAction
        }
        guard expectedGeneration >= 0,
              sequence > 0,
              now.timeIntervalSince1970.isFinite,
              deadline > now,
              acknowledgedCommandIDs.count <= 100,
              Set(acknowledgedCommandIDs).count == acknowledgedCommandIDs.count else {
            throw PhoneRemoteOperationalCodecError.invalidCommand
        }
        let wireCursor: PhoneRemoteWireCursor?
        if let cursor {
            guard cursor.generation > 0,
                  cursor.sequence <= UInt64(Int64.max) else {
                throw PhoneRemoteOperationalCodecError.invalidCommand
            }
            wireCursor = .init(
                generation: cursor.generation,
                lastSequence: Int64(cursor.sequence)
            )
        } else {
            wireCursor = nil
        }
        let payload = try canonicalData(PhoneRemoteWireObserveRequest(
            cursor: wireCursor,
            maximumEvents: 100,
            acknowledgedCommandIDs: acknowledgedCommandIDs
        ))
        return try makeRequest(
            identity: identity,
            pairing: pairing,
            action: .observe,
            wireAction: .observe,
            targetThreadID: Self.inventoryThreadID,
            payload: payload,
            expectedGeneration: expectedGeneration,
            sequence: sequence,
            requestID: requestID,
            commandID: commandID,
            nonce: nonce,
            now: now,
            deadline: deadline
        )
    }

    public func decodeCommandResponse<Bytes: DataProtocol>(
        _ frame: Bytes,
        expectedRequestID: UUID,
        expectedCommandID: UUID,
        expectedDeviceID: UUID,
        expectedPayloadDigest: Data
    ) throws -> PhoneRemoteCommandOutcome {
        let response: PhoneRemoteWireResponse
        do {
            response = try decoder().decode(
                PhoneRemoteWireResponse.self,
                from: unframe(Data(frame))
            )
        } catch let error as PhoneRemoteOperationalCodecError {
            throw error
        } catch {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        guard response.protocolVersion == .current else {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        guard response.requestID == expectedRequestID else {
            throw PhoneRemoteOperationalCodecError.requestIdentityMismatch
        }
        switch response.body {
        case let .rejected(code):
            throw PhoneRemoteOperationalCodecError.rejected(code.rawValue)
        case .observation, .eventBatch:
            throw PhoneRemoteOperationalCodecError.invalidResponse
        case let .commandOutcome(outcome):
            let receipt = outcome.receipt
            guard receipt.commandID == expectedCommandID else {
                throw PhoneRemoteOperationalCodecError.commandIdentityMismatch
            }
            guard receipt.deviceID == expectedDeviceID else {
                throw PhoneRemoteOperationalCodecError.deviceIdentityMismatch
            }
            guard receipt.payloadDigest == expectedPayloadDigest else {
                throw PhoneRemoteOperationalCodecError.payloadDigestMismatch
            }
            guard receipt.payloadDigest.count == 32,
                  receipt.generation > 0,
                  receipt.sequence > 0,
                  receipt.acceptedAt.timeIntervalSince1970.isFinite else {
                throw PhoneRemoteOperationalCodecError.invalidResponse
            }
            return PhoneRemoteCommandOutcome(
                commandID: receipt.commandID,
                deviceID: receipt.deviceID,
                payloadDigest: receipt.payloadDigest,
                generation: receipt.generation,
                sequence: receipt.sequence,
                acceptedAt: receipt.acceptedAt,
                state: Self.phoneState(outcome.state)
            )
        }
    }

    public func decodeObserveResponse<Bytes: DataProtocol>(
        _ frame: Bytes,
        expectedRequestID: UUID,
        expectedCommandID: UUID,
        expectedDeviceID: UUID,
        expectedPayloadDigest: Data,
        expectedCursor: ProjectionCursor? = nil
    ) throws -> PhoneRemoteObserveResponse {
        let response: PhoneRemoteWireResponse
        do {
            response = try decoder().decode(
                PhoneRemoteWireResponse.self,
                from: unframe(Data(frame))
            )
        } catch let error as PhoneRemoteOperationalCodecError {
            throw error
        } catch {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        guard response.protocolVersion == .current else {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        guard response.requestID == expectedRequestID else {
            throw PhoneRemoteOperationalCodecError.requestIdentityMismatch
        }
        switch response.body {
        case let .rejected(code):
            throw PhoneRemoteOperationalCodecError.rejected(code.rawValue)
        case .commandOutcome:
            throw PhoneRemoteOperationalCodecError.invalidResponse
        case let .observation(observation):
            let outcome = try Self.observeOutcome(
                receipt: observation.receipt,
                expectedCommandID: expectedCommandID,
                expectedDeviceID: expectedDeviceID,
                expectedPayloadDigest: expectedPayloadDigest
            )
            let acknowledgements = try Self.acknowledgements(
                observation.acknowledgements,
                expectedDeviceID: expectedDeviceID
            )
            let commandHistory = try Self.commandHistory(
                observation.commandHistory,
                expectedDeviceID: expectedDeviceID
            )
            let snapshot = try Self.snapshot(from: observation.snapshot)
            guard snapshot.cursor.generation == outcome.generation else {
                throw PhoneRemoteOperationalCodecError.invalidResponse
            }
            return PhoneRemoteObserveResponse(
                outcome: outcome,
                acknowledgements: acknowledgements,
                commandHistory: commandHistory,
                payload: .snapshot(snapshot)
            )
        case let .eventBatch(batch):
            let outcome = try Self.observeOutcome(
                receipt: batch.receipt,
                expectedCommandID: expectedCommandID,
                expectedDeviceID: expectedDeviceID,
                expectedPayloadDigest: expectedPayloadDigest
            )
            let acknowledgements = try Self.acknowledgements(
                batch.acknowledgements,
                expectedDeviceID: expectedDeviceID
            )
            let commandHistory = try Self.commandHistory(
                batch.commandHistory,
                expectedDeviceID: expectedDeviceID
            )
            let nextCursor = try Self.validateEventBatch(
                batch,
                expectedCursor: expectedCursor,
                expectedGeneration: outcome.generation
            )
            return PhoneRemoteObserveResponse(
                outcome: outcome,
                acknowledgements: acknowledgements,
                commandHistory: commandHistory,
                payload: .eventsRequireSnapshot(nextCursor: nextCursor)
            )
        }
    }

    private func makeRequest(
        identity: PhoneDeviceIdentity,
        pairing: PhonePairedGuardian,
        action: PhoneAction,
        wireAction: PhoneRemoteCommandAction,
        targetThreadID: String,
        payload: Data,
        expectedGeneration: Int64,
        sequence: UInt64,
        requestID: UUID,
        commandID: UUID,
        nonce: UUID,
        now: Date,
        deadline: Date
    ) throws -> PhonePendingRemoteRequest {
        let payloadDigest = Data(SHA256.hash(data: payload))
        let command = PhoneRemoteWireCommand(
            protocolVersion: .current,
            commandID: commandID,
            deviceID: identity.deviceID,
            expectedGeneration: expectedGeneration,
            sequence: sequence,
            nonce: nonce,
            issuedAt: now,
            deadline: deadline,
            revocationEpoch: pairing.revocationEpoch,
            targetThreadID: targetThreadID,
            action: wireAction,
            force: false,
            payloadDigest: payloadDigest
        )
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: identity.privateKey
            )
        } catch {
            throw PhoneRemoteOperationalCodecError.invalidIdentity
        }
        let signature = try privateKey.signature(for: canonicalData(command))
        let packet = PhoneRemoteWireCommandPacket(
            signedCommand: .init(command: command, signature: signature),
            payload: payload
        )
        let request = PhoneRemoteWireRequest(
            protocolVersion: .current,
            requestID: requestID,
            body: .command(packet)
        )
        let frame = try frame(canonicalData(request))
        let pending = PhonePendingRemoteRequest(
            requestID: requestID,
            commandID: commandID,
            deviceID: identity.deviceID,
            expectedGeneration: expectedGeneration,
            sequence: sequence,
            nonce: nonce,
            targetThreadID: targetThreadID,
            action: action,
            payloadDigest: payloadDigest,
            frame: frame,
            issuedAt: now,
            deadline: deadline
        )
        guard pending.isValid else { throw PhoneRemoteOperationalCodecError.invalidCommand }
        return pending
    }

    private func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw PhoneRemoteOperationalCodecError.invalidFrame }
        guard payload.count <= Self.maximumFrameBytes else {
            throw PhoneRemoteOperationalCodecError.oversizedFrame
        }
        let length = UInt32(payload.count)
        return Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]) + payload
    }

    private func unframe(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw PhoneRemoteOperationalCodecError.invalidFrame }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw PhoneRemoteOperationalCodecError.invalidFrame }
        guard length <= UInt32(Self.maximumFrameBytes) else {
            throw PhoneRemoteOperationalCodecError.oversizedFrame
        }
        guard frame.count == 4 + Int(length) else {
            throw PhoneRemoteOperationalCodecError.invalidFrame
        }
        return frame.subdata(in: 4..<frame.count)
    }

    private func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try encoder().encode(value)
        } catch {
            throw PhoneRemoteOperationalCodecError.invalidFrame
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

    private static func observeOutcome(
        receipt: PhoneRemoteWireReceipt,
        expectedCommandID: UUID,
        expectedDeviceID: UUID,
        expectedPayloadDigest: Data
    ) throws -> PhoneRemoteCommandOutcome {
        guard receipt.commandID == expectedCommandID else {
            throw PhoneRemoteOperationalCodecError.commandIdentityMismatch
        }
        guard receipt.deviceID == expectedDeviceID else {
            throw PhoneRemoteOperationalCodecError.deviceIdentityMismatch
        }
        guard receipt.payloadDigest == expectedPayloadDigest else {
            throw PhoneRemoteOperationalCodecError.payloadDigestMismatch
        }
        guard receipt.payloadDigest.count == 32,
              receipt.generation > 0,
              receipt.sequence > 0,
              receipt.acceptedAt.timeIntervalSince1970.isFinite else {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        return PhoneRemoteCommandOutcome(
            commandID: receipt.commandID,
            deviceID: receipt.deviceID,
            payloadDigest: receipt.payloadDigest,
            generation: receipt.generation,
            sequence: receipt.sequence,
            acceptedAt: receipt.acceptedAt,
            state: .applied(at: receipt.acceptedAt)
        )
    }

    private static func acknowledgements(
        _ values: [PhoneRemoteWireAcknowledgement],
        expectedDeviceID: UUID
    ) throws -> [PhoneRemoteOutcomeAcknowledgement] {
        guard values.count <= 100,
              Set(values.map(\.commandID)).count == values.count,
              values.allSatisfy({
                $0.deviceID == expectedDeviceID
                    && $0.outcomeVersion > 0
                    && $0.acknowledgedAt.timeIntervalSince1970.isFinite
              }) else {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        return values.map {
            PhoneRemoteOutcomeAcknowledgement(
                commandID: $0.commandID,
                deviceID: $0.deviceID,
                outcomeVersion: $0.outcomeVersion,
                acknowledgedAt: $0.acknowledgedAt
            )
        }
    }

    private static func commandHistory(
        _ wire: PhoneRemoteWireCommandHistoryPage?,
        expectedDeviceID: UUID
    ) throws -> PhoneRemoteCommandHistoryPage {
        guard let wire else { return .unavailable }
        let items = wire.items.map { item in
            let receipt = item.outcome.receipt
            return PhoneRemoteCommandHistoryItem(
                action: item.action,
                targetThreadID: item.targetThreadID,
                expectedGeneration: item.expectedGeneration,
                issuedAt: item.issuedAt,
                deadline: item.deadline,
                outcome: PhoneRemoteCommandOutcome(
                    commandID: receipt.commandID,
                    deviceID: receipt.deviceID,
                    payloadDigest: receipt.payloadDigest,
                    generation: receipt.generation,
                    sequence: receipt.sequence,
                    acceptedAt: receipt.acceptedAt,
                    state: phoneState(item.outcome.state)
                ),
                outcomeVersion: item.outcomeVersion,
                updatedAt: item.updatedAt
            )
        }
        let page = PhoneRemoteCommandHistoryPage(
            items: items,
            totalCount: wire.totalCount,
            completeness: {
                switch wire.completeness {
                case .complete: .complete
                case .truncated: .truncated
                }
            }()
        )
        guard page.isValid(for: expectedDeviceID) else {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        return page
    }

    private static func snapshot(
        from wire: PhoneRemoteWireSnapshot
    ) throws -> PhoneRemoteSnapshot {
        let operationHistory = wire.operationHistory?.items ?? []
        guard wire.generation > 0,
              wire.lastSequence >= 0,
              wire.capturedAt.timeIntervalSince1970.isFinite,
              wire.tasks.allSatisfy({
                !$0.threadID.isEmpty
                    && $0.threadID.utf8.count <= 1_024
                    && $0.serverGeneration == wire.generation
                    && $0.eventSequence >= 0
                    && $0.eventSequence <= wire.lastSequence
                    && (0...1).contains($0.confidence)
                    && $0.expiresAt.timeIntervalSince1970.isFinite
                    && $0.expiresAt >= wire.capturedAt
              }),
              Set(wire.tasks.map(\.threadID)).count == wire.tasks.count,
              wire.operationHistory?.isValid != false,
              Set(operationHistory.map(\.operationID)).count == operationHistory.count,
              operationHistory.allSatisfy({
                  !$0.originThreadID.isEmpty
                      && $0.originThreadID.utf8.count <= 1_024
                      && $0.createdAt.timeIntervalSince1970.isFinite
                      && $0.updatedAt.timeIntervalSince1970.isFinite
                      && $0.updatedAt >= $0.createdAt
              }),
              Self.operationHistoryIsCanonical(operationHistory) else {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        return PhoneRemoteSnapshot(
            cursor: .init(
                generation: wire.generation,
                sequence: UInt64(wire.lastSequence)
            ),
            capturedAt: wire.capturedAt,
            inventoryCompleteness: wire.taskInventoryCompleteness,
            tasks: wire.tasks.map {
                PhoneRemoteTaskSnapshot(
                    threadID: $0.threadID,
                    state: $0.state,
                    reason: $0.reason,
                    serverGeneration: $0.serverGeneration,
                    eventSequence: $0.eventSequence,
                    confidence: $0.confidence,
                    expiresAt: $0.expiresAt
                )
            },
            operationHistory: operationHistory.map {
                PhoneRemoteOperationSnapshot(
                    operationID: $0.operationID,
                    kind: $0.kind,
                    originThreadID: $0.originThreadID,
                    phase: $0.phase,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            },
            operationHistoryCompleteness: wire.operationHistory.map {
                switch $0.completeness {
                case .complete: .complete
                case .truncated: .truncated
                }
            } ?? .unavailable,
            operationHistoryTotalCount: wire.operationHistory?.totalCount ?? 0
        )
    }

    private static func operationHistoryIsCanonical(
        _ history: [PhoneRemoteWireOperationHistoryItem]
    ) -> Bool {
        zip(history, history.dropFirst()).allSatisfy { left, right in
            if left.createdAt == right.createdAt {
                return left.operationID.uuidString < right.operationID.uuidString
            }
            return left.createdAt < right.createdAt
        }
    }

    private static func validateEventBatch(
        _ batch: PhoneRemoteWireEventBatch,
        expectedCursor: ProjectionCursor?,
        expectedGeneration: Int64
    ) throws -> ProjectionCursor {
        guard let expectedCursor,
              expectedCursor.generation == expectedGeneration,
              expectedCursor.sequence <= UInt64(Int64.max),
              batch.nextCursor.generation == expectedGeneration,
              batch.nextCursor.lastSequence >= 0,
              batch.events.count <= 100 else {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        var expectedSequence = Int64(expectedCursor.sequence) + 1
        for event in batch.events {
            guard event.generation == expectedGeneration,
                  event.sequence == expectedSequence,
                  event.emittedAt.timeIntervalSince1970.isFinite,
                  (event.kind == .operationChanged) == (event.operationID != nil) else {
                throw PhoneRemoteOperationalCodecError.invalidResponse
            }
            expectedSequence += 1
        }
        let finalSequence = batch.events.last?.sequence ?? Int64(expectedCursor.sequence)
        guard batch.nextCursor.lastSequence == finalSequence else {
            throw PhoneRemoteOperationalCodecError.invalidResponse
        }
        return ProjectionCursor(
            generation: batch.nextCursor.generation,
            sequence: UInt64(batch.nextCursor.lastSequence)
        )
    }

    private static func phoneState(
        _ state: PhoneRemoteWireOutcomeState
    ) -> PhoneCommandState {
        switch state {
        case .pending:
            .accepted
        case let .applied(at):
            .applied(at: at)
        case let .failed(code, at):
            .failed(code: code.rawValue, at: at)
        case let .indeterminate(code, at):
            .indeterminate(code: code.rawValue, at: at)
        }
    }
}

private struct PhoneRemoteWireProtocolVersion: Codable, Equatable, Sendable {
    let major: Int
    let minor: Int
    static let current = PhoneRemoteWireProtocolVersion(major: 1, minor: 0)
}

private struct PhoneRemoteWireCommand: Codable, Equatable, Sendable {
    let protocolVersion: PhoneRemoteWireProtocolVersion
    let commandID: UUID
    let deviceID: UUID
    let expectedGeneration: Int64
    let sequence: UInt64
    let nonce: UUID
    let issuedAt: Date
    let deadline: Date
    let revocationEpoch: UInt64
    let targetThreadID: String
    let action: PhoneRemoteCommandAction
    let force: Bool
    let payloadDigest: Data
}

private struct PhoneRemoteWireSignedCommand: Codable, Equatable, Sendable {
    let command: PhoneRemoteWireCommand
    let signature: Data
}

private struct PhoneRemoteWireCommandPacket: Codable, Equatable, Sendable {
    let signedCommand: PhoneRemoteWireSignedCommand
    let payload: Data
}

private enum PhoneRemoteWireRequestBody: Codable, Equatable, Sendable {
    case command(PhoneRemoteWireCommandPacket)
}

private struct PhoneRemoteWireRequest: Codable, Equatable, Sendable {
    let protocolVersion: PhoneRemoteWireProtocolVersion
    let requestID: UUID
    let body: PhoneRemoteWireRequestBody
}

private struct PhoneRemoteWireCursor: Codable, Equatable, Sendable {
    let generation: Int64
    let lastSequence: Int64
}

private struct PhoneRemoteWireObserveRequest: Codable, Equatable, Sendable {
    let cursor: PhoneRemoteWireCursor?
    let maximumEvents: Int
    let acknowledgedCommandIDs: [UUID]
}

private struct PhoneRemoteWireReceipt: Codable, Equatable, Sendable {
    let commandID: UUID
    let deviceID: UUID
    let payloadDigest: Data
    let generation: Int64
    let sequence: UInt64
    let acceptedAt: Date
}

private struct PhoneRemoteWireAcknowledgement: Codable, Equatable, Sendable {
    let commandID: UUID
    let deviceID: UUID
    let outcomeVersion: Int64
    let acknowledgedAt: Date
}

private struct PhoneRemoteWireTaskSnapshot: Codable, Equatable, Sendable {
    let threadID: String
    let state: PhoneRemoteTaskState
    let reason: String
    let serverGeneration: Int64
    let eventSequence: Int64
    let confidence: Double
    let expiresAt: Date
}

private struct PhoneRemoteWireOperationHistoryItem: Codable, Equatable, Sendable {
    let operationID: UUID
    let kind: PhoneRemoteOperationKind
    let originThreadID: String
    let phase: PhoneRemoteOperationPhase
    let createdAt: Date
    let updatedAt: Date
}

private enum PhoneRemoteWireOperationHistoryCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case truncated
}

private struct PhoneRemoteWireOperationHistoryPage: Codable, Equatable, Sendable {
    let items: [PhoneRemoteWireOperationHistoryItem]
    let totalCount: Int
    let completeness: PhoneRemoteWireOperationHistoryCompleteness

    var isValid: Bool {
        totalCount >= items.count
            && items.count <= 100
            && (completeness == .complete
                ? totalCount == items.count
                : totalCount > items.count)
    }
}

private struct PhoneRemoteWireSnapshot: Codable, Equatable, Sendable {
    let generation: Int64
    let lastSequence: Int64
    let capturedAt: Date
    let operationHistory: PhoneRemoteWireOperationHistoryPage?
    let tasks: [PhoneRemoteWireTaskSnapshot]
    let taskInventoryCompleteness: PhoneRemoteInventoryCompleteness
}

private struct PhoneRemoteWireObservation: Codable, Equatable, Sendable {
    let receipt: PhoneRemoteWireReceipt
    let acknowledgements: [PhoneRemoteWireAcknowledgement]
    let commandHistory: PhoneRemoteWireCommandHistoryPage?
    let snapshot: PhoneRemoteWireSnapshot
}

private enum PhoneRemoteWireEventKind: String, Codable, Equatable, Sendable {
    case operationChanged
    case taskChanged
    case daemonGenerationChanged
}

private struct PhoneRemoteWireEvent: Codable, Equatable, Sendable {
    let generation: Int64
    let sequence: Int64
    let operationID: UUID?
    let emittedAt: Date
    let kind: PhoneRemoteWireEventKind
}

private struct PhoneRemoteWireEventBatch: Codable, Equatable, Sendable {
    let receipt: PhoneRemoteWireReceipt
    let acknowledgements: [PhoneRemoteWireAcknowledgement]
    let commandHistory: PhoneRemoteWireCommandHistoryPage?
    let events: [PhoneRemoteWireEvent]
    let nextCursor: PhoneRemoteWireCursor
}

private enum PhoneRemoteWireFailureCode: String, Codable, Equatable, Sendable {
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

private enum PhoneRemoteWireOutcomeState: Codable, Equatable, Sendable {
    case pending
    case applied(at: Date)
    case failed(code: PhoneRemoteWireFailureCode, at: Date)
    case indeterminate(code: PhoneRemoteWireFailureCode, at: Date)
}

private struct PhoneRemoteWireCommandOutcome: Codable, Equatable, Sendable {
    let receipt: PhoneRemoteWireReceipt
    let state: PhoneRemoteWireOutcomeState
}

private struct PhoneRemoteWireCommandHistoryItem: Codable, Equatable, Sendable {
    let action: PhoneRemoteCommandAction
    let targetThreadID: String
    let expectedGeneration: Int64
    let issuedAt: Date
    let deadline: Date
    let outcome: PhoneRemoteWireCommandOutcome
    let outcomeVersion: Int64
    let updatedAt: Date
}

private enum PhoneRemoteWireCommandHistoryCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case truncated
}

private struct PhoneRemoteWireCommandHistoryPage: Codable, Equatable, Sendable {
    let items: [PhoneRemoteWireCommandHistoryItem]
    let totalCount: Int
    let completeness: PhoneRemoteWireCommandHistoryCompleteness
}

private enum PhoneRemoteWireErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case unauthorized
    case deadlineExceeded
    case snapshotRequired
    case serverUnavailable
}

private enum PhoneRemoteWireResponseBody: Codable, Equatable, Sendable {
    case commandOutcome(PhoneRemoteWireCommandOutcome)
    case observation(PhoneRemoteWireObservation)
    case eventBatch(PhoneRemoteWireEventBatch)
    case rejected(PhoneRemoteWireErrorCode)
}

private struct PhoneRemoteWireResponse: Codable, Equatable, Sendable {
    let protocolVersion: PhoneRemoteWireProtocolVersion
    let requestID: UUID
    let body: PhoneRemoteWireResponseBody
}
