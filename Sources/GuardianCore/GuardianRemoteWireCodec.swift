import Foundation

public struct GuardianRemoteSnapshotRequest: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let cursor: GuardianRemoteSessionCursor?
    public let deadline: Date

    public init(
        deviceID: UUID,
        cursor: GuardianRemoteSessionCursor?,
        deadline: Date
    ) {
        self.deviceID = deviceID
        self.cursor = cursor
        self.deadline = deadline
    }
}

public struct GuardianRemotePairingRequest: Codable, Equatable, Sendable {
    public let invitation: GuardianSignedPairingPayload
    public let claim: GuardianSignedPairingClaim

    public init(
        invitation: GuardianSignedPairingPayload,
        claim: GuardianSignedPairingClaim
    ) {
        self.invitation = invitation
        self.claim = claim
    }
}

public struct GuardianRemotePairingReceipt: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let capabilities: GuardianRemoteCapabilities
    public let pairingEpoch: UInt64
    public let revocationEpoch: UInt64
    public let pairedAt: Date

    public init(
        deviceID: UUID,
        capabilities: GuardianRemoteCapabilities,
        pairingEpoch: UInt64,
        revocationEpoch: UInt64,
        pairedAt: Date
    ) {
        self.deviceID = deviceID
        self.capabilities = capabilities
        self.pairingEpoch = pairingEpoch
        self.revocationEpoch = revocationEpoch
        self.pairedAt = pairedAt
    }
}

public enum GuardianRemoteWireRequestBody: Codable, Equatable, Sendable {
    case command(GuardianRemoteCommandPacket)
    case pairing(GuardianRemotePairingRequest)
    case snapshot(GuardianRemoteSnapshotRequest)
    case ping(UUID)
}

public struct GuardianRemoteWireRequest: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianRemoteProtocolVersion
    public let requestID: UUID
    public let body: GuardianRemoteWireRequestBody

    public init(
        protocolVersion: GuardianRemoteProtocolVersion,
        requestID: UUID,
        body: GuardianRemoteWireRequestBody
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.body = body
    }
}

public enum GuardianRemoteWireResponseBody: Codable, Equatable, Sendable {
    case paired(GuardianRemotePairingReceipt)
    case gateway(GuardianRemoteGatewayResponse)
    case commandOutcome(GuardianRemoteCommandOutcome)
    case observation(GuardianRemoteObservation)
    case eventBatch(GuardianRemoteEventBatch)
    case snapshot(GuardianIPCFullSnapshot)
    case event(GuardianIPCEvent)
    case pong(UUID)
    case rejected(GuardianRemoteWireErrorCode)
}

public struct GuardianRemoteWireResponse: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianRemoteProtocolVersion
    public let requestID: UUID
    public let body: GuardianRemoteWireResponseBody

    public init(
        protocolVersion: GuardianRemoteProtocolVersion,
        requestID: UUID,
        body: GuardianRemoteWireResponseBody
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.body = body
    }
}

public enum GuardianRemoteWireErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case unauthorized
    case deadlineExceeded
    case snapshotRequired
    case serverUnavailable
}

public enum GuardianRemoteWireError: Error, Equatable, Sendable {
    case truncated
    case oversized
    case trailingBytes
    case invalidPayload
    case unauthenticatedRequest
    case unsupportedProtocol(GuardianRemoteProtocolVersion)
}

public struct GuardianRemoteWireCodec: Sendable {
    public static let maximumFrameBytes = 512 * 1_024

    public init() {}

    public func encode(_ request: GuardianRemoteWireRequest) throws -> Data {
        try encodeValue(request)
    }

    public func encode(_ response: GuardianRemoteWireResponse) throws -> Data {
        try encodeValue(response)
    }

    public func decodeRequest<Bytes: DataProtocol>(
        _ frame: Bytes
    ) throws -> GuardianRemoteWireRequest {
        let payload = try decodePayload(Data(frame))
        let request: GuardianRemoteWireRequest
        do {
            request = try decoder().decode(GuardianRemoteWireRequest.self, from: payload)
        } catch {
            throw GuardianRemoteWireError.invalidPayload
        }
        guard request.protocolVersion == .current else {
            throw GuardianRemoteWireError.unsupportedProtocol(request.protocolVersion)
        }
        if case .snapshot = request.body {
            throw GuardianRemoteWireError.unauthenticatedRequest
        }
        return request
    }

    public func decodeResponse<Bytes: DataProtocol>(
        _ frame: Bytes
    ) throws -> GuardianRemoteWireResponse {
        let payload = try decodePayload(Data(frame))
        let response: GuardianRemoteWireResponse
        do {
            response = try decoder().decode(GuardianRemoteWireResponse.self, from: payload)
        } catch {
            throw GuardianRemoteWireError.invalidPayload
        }
        guard response.protocolVersion == .current else {
            throw GuardianRemoteWireError.unsupportedProtocol(response.protocolVersion)
        }
        return response
    }

    private func encodeValue<Value: Encodable>(_ value: Value) throws -> Data {
        let payload: Data
        do {
            payload = try encoder().encode(value)
        } catch {
            throw GuardianRemoteWireError.invalidPayload
        }
        guard !payload.isEmpty,
              payload.count <= Self.maximumFrameBytes else {
            throw GuardianRemoteWireError.oversized
        }
        let length = UInt32(payload.count)
        return Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]) + payload
    }

    private func decodePayload(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw GuardianRemoteWireError.truncated }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw GuardianRemoteWireError.invalidPayload }
        guard length <= UInt32(Self.maximumFrameBytes) else {
            throw GuardianRemoteWireError.oversized
        }
        let expectedCount = 4 + Int(length)
        guard frame.count >= expectedCount else { throw GuardianRemoteWireError.truncated }
        guard frame.count == expectedCount else { throw GuardianRemoteWireError.trailingBytes }
        return frame.subdata(in: 4..<expectedCount)
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
