import CryptoKit
import Foundation

public enum PhonePairingCodeError: Error, Equatable, Sendable {
    case invalidCode
    case unsupportedProtocol
    case invalidEndpoint
    case expired
    case invalidSignature
}

public enum PhoneCertificatePin {
    public static func matches(
        leafCertificateDER: Data,
        expectedSHA256: Data
    ) -> Bool {
        guard !leafCertificateDER.isEmpty, expectedSHA256.count == 32 else { return false }
        return Data(SHA256.hash(data: leafCertificateDER)) == expectedSHA256
    }
}

public struct PhonePairingInvitation: Equatable, Sendable {
    public let guardianID: UUID
    public let guardianPublicKey: Data
    public let endpointHost: String
    public let endpointPort: UInt16
    public let tlsCertificateHash: Data
    public let challengeNonce: UUID
    public let expiresAt: Date
    public let allowedCapabilities: Set<PhoneAction>
    public let allowedCapabilityBits: UInt64
    public let encodedSignedInvitation: Data
}

public struct PhoneDeviceIdentity: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let privateKey: Data

    public init(deviceID: UUID, privateKey: Data) {
        self.deviceID = deviceID
        self.privateKey = privateKey
    }

    public var isValid: Bool {
        privateKey.count == 32
            && (try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)) != nil
    }
}

public struct PhonePendingPairingRequest: Equatable, Sendable {
    public let requestID: UUID
    public let deviceID: UUID
    public let frame: Data
}

public struct PhoneRemotePairingReceipt: Equatable, Sendable {
    public let deviceID: UUID
    public let pairingEpoch: UInt64
    public let revocationEpoch: UInt64
    public let pairedAt: Date
    public let capabilities: Set<PhoneAction>
}

public enum PhoneRemotePairingWireError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidInvitation
    case capabilityEscalation
    case invalidRequest
    case oversized
    case invalidResponse
    case requestIdentityMismatch
    case rejected(String)
}

public struct PhoneRemotePairingWireCodec: Sendable {
    public static let maximumFrameBytes = 512 * 1_024

    public init() {}

    public static func normalizedActions(
        for requestedActions: Set<PhoneAction>
    ) -> Set<PhoneAction> {
        phoneActions(for: remoteCapabilities(for: requestedActions))
    }

    public func makeRequest(
        invitation: PhonePairingInvitation,
        identity: PhoneDeviceIdentity,
        requestedActions: Set<PhoneAction>,
        requestID: UUID = UUID(),
        now: Date = Date()
    ) throws -> PhonePendingPairingRequest {
        guard identity.isValid else { throw PhoneRemotePairingWireError.invalidIdentity }
        guard now.timeIntervalSince1970.isFinite,
              invitation.expiresAt > now,
              let signedInvitation = try? Self.decoder().decode(
                PhoneSignedPairingPayload.self,
                from: invitation.encodedSignedInvitation
              ) else {
            throw PhoneRemotePairingWireError.invalidInvitation
        }
        let capabilities = Self.remoteCapabilities(for: requestedActions)
        guard capabilities.contains(.observe),
              capabilities.rawValue & ~invitation.allowedCapabilityBits == 0 else {
            throw PhoneRemotePairingWireError.capabilityEscalation
        }
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.privateKey
        )
        let claim = PhonePairingClaim(
            protocolVersion: .current,
            guardianID: invitation.guardianID,
            challengeNonce: invitation.challengeNonce,
            deviceID: identity.deviceID,
            devicePublicKey: privateKey.publicKey.rawRepresentation,
            requestedCapabilities: capabilities,
            issuedAt: now
        )
        let signedClaim = PhoneSignedPairingClaim(
            claim: claim,
            signature: try privateKey.signature(for: Self.canonicalData(claim))
        )
        let request = PhoneRemoteWireRequest(
            protocolVersion: .current,
            requestID: requestID,
            body: .pairing(.init(
                invitation: signedInvitation,
                claim: signedClaim
            ))
        )
        return PhonePendingPairingRequest(
            requestID: requestID,
            deviceID: identity.deviceID,
            frame: try Self.frame(Self.encoder().encode(request))
        )
    }

    public func decodeResponse(
        _ frame: Data,
        expectedRequestID: UUID
    ) throws -> PhoneRemotePairingReceipt {
        let payload = try Self.unframe(frame)
        guard let response = try? Self.decoder().decode(
            PhoneRemoteWireResponse.self,
            from: payload
        ), response.protocolVersion == .current else {
            throw PhoneRemotePairingWireError.invalidResponse
        }
        guard response.requestID == expectedRequestID else {
            throw PhoneRemotePairingWireError.requestIdentityMismatch
        }
        switch response.body {
        case let .rejected(code):
            throw PhoneRemotePairingWireError.rejected(code.rawValue)
        case let .paired(receipt):
            guard receipt.pairingEpoch > 0,
                  receipt.pairedAt.timeIntervalSince1970.isFinite,
                  receipt.capabilities.contains(.observe),
                  receipt.capabilities.rawValue & ~PhoneRemoteCapabilities.knownMask == 0 else {
                throw PhoneRemotePairingWireError.invalidResponse
            }
            return PhoneRemotePairingReceipt(
                deviceID: receipt.deviceID,
                pairingEpoch: receipt.pairingEpoch,
                revocationEpoch: receipt.revocationEpoch,
                pairedAt: receipt.pairedAt,
                capabilities: Self.phoneActions(for: receipt.capabilities)
            )
        }
    }

    private static func remoteCapabilities(
        for actions: Set<PhoneAction>
    ) -> PhoneRemoteCapabilities {
        var value: PhoneRemoteCapabilities = []
        if actions.contains(.observe) { value.insert(.observe) }
        if !actions.isDisjoint(with: [.promptAgent, .steerAgent, .interruptAgent]) {
            value.insert(.prompt)
        }
        if !actions.isDisjoint(with: [.approve, .deny]) { value.insert(.approve) }
        if actions.contains(.repair) { value.insert(.repair) }
        if !actions.isDisjoint(with: [.restartAgent, .cancelRecovery]) {
            value.insert(.policyRecovery)
        }
        if actions.contains(.readFiles) { value.insert(.files) }
        return value
    }

    private static func phoneActions(
        for capabilities: PhoneRemoteCapabilities
    ) -> Set<PhoneAction> {
        var actions: Set<PhoneAction> = []
        if capabilities.contains(.observe) { actions.insert(.observe) }
        if capabilities.contains(.prompt) { actions.insert(.promptAgent) }
        if capabilities.contains(.approve) { actions.formUnion([.approve, .deny]) }
        if capabilities.contains(.repair) { actions.insert(.repair) }
        if capabilities.contains(.policyRecovery) {
            actions.formUnion([.restartAgent, .cancelRecovery])
        }
        if capabilities.contains(.files) { actions.insert(.readFiles) }
        return actions
    }

    private static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw PhoneRemotePairingWireError.invalidRequest }
        guard payload.count <= maximumFrameBytes else {
            throw PhoneRemotePairingWireError.oversized
        }
        let length = UInt32(payload.count)
        return Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]) + payload
    }

    private static func unframe(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw PhoneRemotePairingWireError.invalidResponse }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumFrameBytes) else {
            throw PhoneRemotePairingWireError.invalidResponse
        }
        let expected = 4 + Int(length)
        guard frame.count == expected else { throw PhoneRemotePairingWireError.invalidResponse }
        return frame.subdata(in: 4..<expected)
    }

    private static func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
        try encoder().encode(value)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public struct PhonePairingCodeDecoder: Sendable {
    public static let maximumPayloadBytes = 64 * 1_024

    public init() {}

    public func decode(_ code: String, now: Date = Date()) throws -> PhonePairingInvitation {
        guard now.timeIntervalSince1970.isFinite,
              code.utf8.count <= Self.maximumPayloadBytes * 2,
              let components = URLComponents(string: code),
              components.scheme == "codexguardian",
              components.host == "pair",
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "payload",
              let encoded = components.queryItems?.first?.value,
              let data = Self.decodeBase64URL(encoded),
              !data.isEmpty,
              data.count <= Self.maximumPayloadBytes else {
            throw PhonePairingCodeError.invalidCode
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let signed = try? decoder.decode(PhoneSignedPairingPayload.self, from: data) else {
            throw PhonePairingCodeError.invalidCode
        }
        let payload = signed.payload
        guard payload.protocolVersion == .current else {
            throw PhonePairingCodeError.unsupportedProtocol
        }
        guard payload.guardianPublicKey.count == 32,
              payload.tlsCertificateHash.count == 32,
              payload.challenge.guardianIdentityHash.count == 32,
              signed.signature.count == 64,
              payload.allowedCapabilities.contains(.observe),
              payload.allowedCapabilities.rawValue & ~PhoneRemoteCapabilities.knownMask == 0,
              payload.issuedAt.timeIntervalSince1970.isFinite,
              payload.issuedAt <= now.addingTimeInterval(30),
              payload.challenge.expiresAt.timeIntervalSince1970.isFinite,
              payload.challenge.consumedAt == nil else {
            throw PhonePairingCodeError.invalidCode
        }
        guard payload.challenge.expiresAt > now else {
            throw PhonePairingCodeError.expired
        }
        guard PhonePrivateEndpointPolicy.allows(payload.endpointHost),
              payload.endpointPort > 0 else {
            throw PhonePairingCodeError.invalidEndpoint
        }
        let identityHash = Data(SHA256.hash(data: payload.guardianPublicKey))
        guard identityHash == payload.challenge.guardianIdentityHash,
              let key = try? Curve25519.Signing.PublicKey(
                rawRepresentation: payload.guardianPublicKey
              ) else {
            throw PhonePairingCodeError.invalidSignature
        }
        let canonical = try Self.canonicalData(payload)
        guard key.isValidSignature(signed.signature, for: canonical) else {
            throw PhonePairingCodeError.invalidSignature
        }

        var capabilities: Set<PhoneAction> = [.observe]
        if payload.allowedCapabilities.contains(.prompt) { capabilities.insert(.promptAgent) }
        if payload.allowedCapabilities.contains(.approve) {
            capabilities.formUnion([.approve, .deny])
        }
        if payload.allowedCapabilities.contains(.repair) { capabilities.insert(.repair) }
        if payload.allowedCapabilities.contains(.policyRecovery) {
            capabilities.formUnion([.restartAgent, .cancelRecovery])
        }
        if payload.allowedCapabilities.contains(.files) { capabilities.insert(.readFiles) }

        return PhonePairingInvitation(
            guardianID: payload.guardianID,
            guardianPublicKey: payload.guardianPublicKey,
            endpointHost: payload.endpointHost,
            endpointPort: payload.endpointPort,
            tlsCertificateHash: payload.tlsCertificateHash,
            challengeNonce: payload.challenge.nonce,
            expiresAt: payload.challenge.expiresAt,
            allowedCapabilities: capabilities,
            allowedCapabilityBits: payload.allowedCapabilities.rawValue,
            encodedSignedInvitation: data
        )
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.range(of: "[^A-Za-z0-9_-]", options: .regularExpression) == nil else {
            return nil
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func canonicalData(_ value: PhonePairingPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
}

private struct PhoneRemoteProtocolVersion: Codable, Equatable, Sendable {
    let major: Int
    let minor: Int
    static let current = Self(major: 1, minor: 0)
}

private struct PhoneRemoteCapabilities: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt64
    static let observe = Self(rawValue: 1 << 0)
    static let prompt = Self(rawValue: 1 << 1)
    static let approve = Self(rawValue: 1 << 2)
    static let repair = Self(rawValue: 1 << 3)
    static let policyRecovery = Self(rawValue: 1 << 4)
    static let files = Self(rawValue: 1 << 5)
    static let knownMask: UInt64 = (1 << 7) - 1
}

private struct PhonePairingChallenge: Codable, Equatable, Sendable {
    let nonce: UUID
    let guardianIdentityHash: Data
    let expiresAt: Date
    let consumedAt: Date?
}

private struct PhonePairingPayload: Codable, Equatable, Sendable {
    let protocolVersion: PhoneRemoteProtocolVersion
    let guardianID: UUID
    let guardianPublicKey: Data
    let tlsCertificateHash: Data
    let endpointHost: String
    let endpointPort: UInt16
    let challenge: PhonePairingChallenge
    let allowedCapabilities: PhoneRemoteCapabilities
    let issuedAt: Date
}

private struct PhoneSignedPairingPayload: Codable, Equatable, Sendable {
    let payload: PhonePairingPayload
    let signature: Data
}

private struct PhonePairingClaim: Codable, Equatable, Sendable {
    let protocolVersion: PhoneRemoteProtocolVersion
    let guardianID: UUID
    let challengeNonce: UUID
    let deviceID: UUID
    let devicePublicKey: Data
    let requestedCapabilities: PhoneRemoteCapabilities
    let issuedAt: Date
}

private struct PhoneSignedPairingClaim: Codable, Equatable, Sendable {
    let claim: PhonePairingClaim
    let signature: Data
}

private struct PhoneRemotePairingRequest: Codable, Equatable, Sendable {
    let invitation: PhoneSignedPairingPayload
    let claim: PhoneSignedPairingClaim
}

private enum PhoneRemoteWireRequestBody: Codable, Equatable, Sendable {
    case pairing(PhoneRemotePairingRequest)
}

private struct PhoneRemoteWireRequest: Codable, Equatable, Sendable {
    let protocolVersion: PhoneRemoteProtocolVersion
    let requestID: UUID
    let body: PhoneRemoteWireRequestBody
}

private struct PhoneRemotePairingReceiptWire: Codable, Equatable, Sendable {
    let deviceID: UUID
    let capabilities: PhoneRemoteCapabilities
    let pairingEpoch: UInt64
    let revocationEpoch: UInt64
    let pairedAt: Date
}

private enum PhoneRemoteWireErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case unauthorized
    case deadlineExceeded
    case snapshotRequired
    case serverUnavailable
}

private enum PhoneRemoteWireResponseBody: Codable, Equatable, Sendable {
    case paired(PhoneRemotePairingReceiptWire)
    case rejected(PhoneRemoteWireErrorCode)
}

private struct PhoneRemoteWireResponse: Codable, Equatable, Sendable {
    let protocolVersion: PhoneRemoteProtocolVersion
    let requestID: UUID
    let body: PhoneRemoteWireResponseBody
}

enum PhonePrivateEndpointPolicy {
    static func allows(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        if value == "localhost" || value.hasSuffix(".local") || value == "::1" {
            return true
        }
        if value.hasPrefix("fc") || value.hasPrefix("fd") || value.hasPrefix("fe80:") {
            return true
        }
        let parts = value.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 100 && (64...127).contains(parts[1]) { return true }
        return false
    }
}
