import CryptoKit
import Foundation

public enum GuardianRemoteGatewayRejection: Codable, Equatable, Sendable {
    case unknownDevice
    case payloadTooLarge
    case payloadDigestMismatch
    case invalidPayload
    case payloadProtectionUnavailable
    case adapterUnavailable
    case signature(GuardianRemoteSignatureRejection)
}

public enum GuardianRemoteGatewayResponse: Codable, Equatable, Sendable {
    case reconciled(GuardianRemoteReconciliation)
    case rejected(GuardianRemoteGatewayRejection)
}

public struct GuardianRemoteRevocationResult: Equatable, Sendable {
    public let device: GuardianRemoteDevice
    public let closedSessionIDs: [UUID]

    public init(device: GuardianRemoteDevice, closedSessionIDs: [UUID]) {
        self.device = device
        self.closedSessionIDs = closedSessionIDs
    }
}

public actor GuardianRemoteGatewayCore {
    public typealias PayloadSealer = @Sendable (
        GuardianRemoteCommand,
        Data
    ) async throws -> GuardianRemoteSealedPayload

    private let journal: GuardianJournal
    private let sessions: GuardianRemoteSessionHub
    private let payloadSealer: PayloadSealer
    private let supportedActions: [GuardianRemoteAction]
    private let authenticator = GuardianRemoteCommandAuthenticator()

    public init(
        journal: GuardianJournal,
        sessions: GuardianRemoteSessionHub = GuardianRemoteSessionHub(),
        supportedActions: [GuardianRemoteAction] = [.observe],
        payloadSealer: @escaping PayloadSealer
    ) {
        self.journal = journal
        self.sessions = sessions
        self.supportedActions = supportedActions
        self.payloadSealer = payloadSealer
    }

    public func handle(
        _ packet: GuardianRemoteCommandPacket,
        currentGeneration: Int64,
        now: Date = Date()
    ) async throws -> GuardianRemoteGatewayResponse {
        let signed = packet.signedCommand
        guard packet.payload.count <= 256 * 1_024 else {
            try journal.recordRemoteCommandRejection(
                signed.command,
                reason: .payloadTooLarge,
                currentGeneration: currentGeneration,
                at: now
            )
            return .rejected(.payloadTooLarge)
        }
        guard Data(SHA256.hash(data: packet.payload)) == signed.command.payloadDigest else {
            try journal.recordRemoteCommandRejection(
                signed.command,
                reason: .payloadDigestMismatch,
                currentGeneration: currentGeneration,
                at: now
            )
            return .rejected(.payloadDigestMismatch)
        }
        guard let device = try journal.remoteDevice(id: signed.command.deviceID) else {
            try journal.recordRemoteCommandRejection(
                signed.command,
                reason: .unknownDevice,
                currentGeneration: currentGeneration,
                at: now
            )
            return .rejected(.unknownDevice)
        }
        switch try authenticator.verify(signed, device: device) {
        case let .rejected(reason):
            try journal.recordRemoteCommandRejection(
                signed.command,
                reason: Self.auditReason(for: reason),
                currentGeneration: currentGeneration,
                at: now
            )
            return .rejected(.signature(reason))
        case let .authenticated(command):
            guard Self.payloadIsValid(packet.payload, for: command.action) else {
                try journal.recordRemoteCommandRejection(
                    command,
                    reason: .invalidPayload,
                    currentGeneration: currentGeneration,
                    at: now
                )
                return .rejected(.invalidPayload)
            }
            guard supportedActions.contains(command.action) else {
                try journal.recordRemoteCommandRejection(
                    command,
                    reason: .adapterUnavailable,
                    currentGeneration: currentGeneration,
                    at: now
                )
                return .rejected(.adapterUnavailable)
            }
            if command.action == .observe {
                return .reconciled(try journal.reconcileRemoteCommand(
                    command,
                    sealedPayload: nil,
                    currentGeneration: currentGeneration,
                    now: now
                ))
            }
            let sealedPayload: GuardianRemoteSealedPayload
            do {
                sealedPayload = try await payloadSealer(command, packet.payload)
                guard sealedPayload.isValid else {
                    throw GuardianRemotePayloadCipherError.invalidEnvelope
                }
            } catch {
                try journal.recordRemoteCommandRejection(
                    command,
                    reason: .payloadProtectionUnavailable,
                    currentGeneration: currentGeneration,
                    at: now
                )
                return .rejected(.payloadProtectionUnavailable)
            }
            return .reconciled(try journal.reconcileRemoteCommand(
                command,
                sealedPayload: sealedPayload,
                currentGeneration: currentGeneration,
                now: now
            ))
        }
    }

    public func openSession(
        id: UUID,
        deviceID: UUID,
        cursor: GuardianRemoteSessionCursor
    ) async throws -> Bool {
        guard let device = try journal.remoteDevice(id: deviceID) else { return false }
        return await sessions.open(sessionID: id, device: device, cursor: cursor)
    }

    public func closeSession(id: UUID) async {
        await sessions.close(sessionID: id)
    }

    public func revokeDevice(
        id: UUID,
        expectedRevocationEpoch: UInt64,
        at date: Date = Date()
    ) async throws -> GuardianRemoteRevocationResult {
        let device = try journal.revokeRemoteDevice(
            id: id,
            expectedRevocationEpoch: expectedRevocationEpoch,
            at: date
        )
        let closed = await sessions.revoke(deviceID: id, at: date)
        return GuardianRemoteRevocationResult(
            device: device,
            closedSessionIDs: closed
        )
    }

    public func activeSessionCount(deviceID: UUID) async -> Int {
        await sessions.activeSessionCount(deviceID: deviceID)
    }

    public func commandOutcome(commandID: UUID) throws -> GuardianRemoteCommandOutcome? {
        try journal.remoteCommandOutcome(commandID: commandID)
    }

    public func commandHistory(
        deviceID: UUID
    ) throws -> GuardianRemoteCommandHistoryPage {
        try journal.remoteCommandHistory(deviceID: deviceID)
    }

    public func acknowledgeOutcomes(
        deviceID: UUID,
        commandIDs: [UUID],
        at date: Date = Date()
    ) throws -> [GuardianRemoteOutcomeAcknowledgement] {
        guard commandIDs.count <= 100,
              Set(commandIDs).count == commandIDs.count else {
            throw GuardianJournalError.invalidRemoteRecord
        }
        return try journal.ackRemoteCommandOutcomes(
            deviceID: deviceID,
            commandIDs: commandIDs,
            at: date
        )
    }

    private static func auditReason(
        for reason: GuardianRemoteSignatureRejection
    ) -> GuardianRemoteCommandAuditRejection {
        switch reason {
        case .deviceIdentityMismatch: .deviceIdentityMismatch
        case .invalidPublicKey: .invalidPublicKey
        case .invalidSignature: .invalidSignature
        }
    }

    private static func payloadIsValid(
        _ payload: Data,
        for action: GuardianRemoteAction
    ) -> Bool {
        guard action == .observe else { return true }
        if payload.isEmpty { return true }
        guard let request = try? JSONDecoder().decode(
            GuardianRemoteObserveRequest.self,
            from: payload
        ) else { return false }
        return request.isValid
    }
}
