import CryptoKit
import Foundation

public struct GuardianRemoteSignedCommand: Codable, Equatable, Sendable {
    public let command: GuardianRemoteCommand
    public let signature: Data

    public init(command: GuardianRemoteCommand, signature: Data) {
        self.command = command
        self.signature = signature
    }
}

public struct GuardianRemoteCommandPacket: Codable, Equatable, Sendable {
    public let signedCommand: GuardianRemoteSignedCommand
    public let payload: Data

    public init(signedCommand: GuardianRemoteSignedCommand, payload: Data) {
        self.signedCommand = signedCommand
        self.payload = payload
    }
}

public enum GuardianRemoteSignatureRejection: Codable, Equatable, Sendable {
    case deviceIdentityMismatch
    case invalidPublicKey
    case invalidSignature
}

public enum GuardianRemoteSignatureValidation: Codable, Equatable, Sendable {
    case authenticated(GuardianRemoteCommand)
    case rejected(GuardianRemoteSignatureRejection)
}

public struct GuardianRemoteCommandAuthenticator: Sendable {
    public init() {}

    public func sign(
        _ command: GuardianRemoteCommand,
        using privateKey: Curve25519.Signing.PrivateKey
    ) throws -> GuardianRemoteSignedCommand {
        let signature = try privateKey.signature(
            for: GuardianRemoteCanonicalEncoding.data(command)
        )
        return GuardianRemoteSignedCommand(command: command, signature: signature)
    }

    public func verify(
        _ signed: GuardianRemoteSignedCommand,
        device: GuardianRemoteDevice
    ) throws -> GuardianRemoteSignatureValidation {
        guard signed.command.deviceID == device.id else {
            return .rejected(.deviceIdentityMismatch)
        }
        guard device.publicKey.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: device.publicKey
              ) else {
            return .rejected(.invalidPublicKey)
        }
        let payload = try GuardianRemoteCanonicalEncoding.data(signed.command)
        guard publicKey.isValidSignature(signed.signature, for: payload) else {
            return .rejected(.invalidSignature)
        }
        return .authenticated(signed.command)
    }
}

public struct GuardianPairingPayload: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianRemoteProtocolVersion
    public let guardianID: UUID
    public let guardianPublicKey: Data
    public let tlsCertificateHash: Data
    public let endpointHost: String
    public let endpointPort: UInt16
    public let challenge: GuardianPairingChallenge
    public let allowedCapabilities: GuardianRemoteCapabilities
    public let issuedAt: Date

    public init(
        protocolVersion: GuardianRemoteProtocolVersion,
        guardianID: UUID,
        guardianPublicKey: Data,
        tlsCertificateHash: Data,
        endpointHost: String,
        endpointPort: UInt16,
        challenge: GuardianPairingChallenge,
        allowedCapabilities: GuardianRemoteCapabilities = [.observe],
        issuedAt: Date
    ) {
        self.protocolVersion = protocolVersion
        self.guardianID = guardianID
        self.guardianPublicKey = guardianPublicKey
        self.tlsCertificateHash = tlsCertificateHash
        self.endpointHost = endpointHost
        self.endpointPort = endpointPort
        self.challenge = challenge
        self.allowedCapabilities = allowedCapabilities
        self.issuedAt = issuedAt
    }
}

public struct GuardianSignedPairingPayload: Codable, Equatable, Sendable {
    public let payload: GuardianPairingPayload
    public let signature: Data

    public init(payload: GuardianPairingPayload, signature: Data) {
        self.payload = payload
        self.signature = signature
    }
}

public enum GuardianPairingAuthenticationRejection: Codable, Equatable, Sendable {
    case unsupportedProtocol
    case invalidPayload
    case identityMismatch
    case expired
    case alreadyConsumed
    case invalidSignature
}

public enum GuardianPairingAuthentication: Codable, Equatable, Sendable {
    case authenticated(GuardianPairingPayload)
    case rejected(GuardianPairingAuthenticationRejection)
}

public struct GuardianPairingAuthenticator: Sendable {
    public init() {}

    public func sign(
        _ payload: GuardianPairingPayload,
        using privateKey: Curve25519.Signing.PrivateKey
    ) throws -> GuardianSignedPairingPayload {
        guard privateKey.publicKey.rawRepresentation == payload.guardianPublicKey else {
            throw GuardianRemoteCryptoError.identityMismatch
        }
        let signature = try privateKey.signature(
            for: GuardianRemoteCanonicalEncoding.data(payload)
        )
        return GuardianSignedPairingPayload(payload: payload, signature: signature)
    }

    public func verify(
        _ signed: GuardianSignedPairingPayload,
        expectedIdentityHash: Data,
        now: Date
    ) throws -> GuardianPairingAuthentication {
        let payload = signed.payload
        guard payload.protocolVersion == .current else {
            return .rejected(.unsupportedProtocol)
        }
        guard payload.guardianPublicKey.count == 32,
              payload.tlsCertificateHash.count == 32,
              expectedIdentityHash.count == 32,
              !payload.endpointHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.endpointPort > 0,
              payload.allowedCapabilities.contains(.observe),
              payload.allowedCapabilities.rawValue & ~((1 << 7) - 1) == 0,
              payload.issuedAt.timeIntervalSince1970.isFinite,
              payload.issuedAt <= now.addingTimeInterval(30) else {
            return .rejected(.invalidPayload)
        }
        guard case .allowed = GuardianRemotePeerAddressPolicy().evaluate(
            payload.endpointHost
        ) else {
            return .rejected(.invalidPayload)
        }
        let actualIdentityHash = Data(SHA256.hash(data: payload.guardianPublicKey))
        guard actualIdentityHash == expectedIdentityHash,
              payload.challenge.guardianIdentityHash == expectedIdentityHash else {
            return .rejected(.identityMismatch)
        }
        switch GuardianPairingPolicy().validate(
            payload.challenge,
            expectedGuardianIdentityHash: expectedIdentityHash,
            now: now
        ) {
        case .accepted:
            break
        case .rejected(.expired):
            return .rejected(.expired)
        case .rejected(.alreadyConsumed):
            return .rejected(.alreadyConsumed)
        case .rejected(.identityMismatch):
            return .rejected(.identityMismatch)
        case .rejected(.invalidChallenge):
            return .rejected(.invalidPayload)
        }
        guard let publicKey = try? Curve25519.Signing.PublicKey(
            rawRepresentation: payload.guardianPublicKey
        ) else {
            return .rejected(.invalidPayload)
        }
        let encoded = try GuardianRemoteCanonicalEncoding.data(payload)
        guard publicKey.isValidSignature(signed.signature, for: encoded) else {
            return .rejected(.invalidSignature)
        }
        return .authenticated(payload)
    }
}

public struct GuardianPairingClaim: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianRemoteProtocolVersion
    public let guardianID: UUID
    public let challengeNonce: UUID
    public let deviceID: UUID
    public let devicePublicKey: Data
    public let requestedCapabilities: GuardianRemoteCapabilities
    public let issuedAt: Date

    public init(
        protocolVersion: GuardianRemoteProtocolVersion,
        guardianID: UUID,
        challengeNonce: UUID,
        deviceID: UUID,
        devicePublicKey: Data,
        requestedCapabilities: GuardianRemoteCapabilities,
        issuedAt: Date
    ) {
        self.protocolVersion = protocolVersion
        self.guardianID = guardianID
        self.challengeNonce = challengeNonce
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.requestedCapabilities = requestedCapabilities
        self.issuedAt = issuedAt
    }
}

public struct GuardianSignedPairingClaim: Codable, Equatable, Sendable {
    public let claim: GuardianPairingClaim
    public let signature: Data

    public init(claim: GuardianPairingClaim, signature: Data) {
        self.claim = claim
        self.signature = signature
    }
}

public enum GuardianPairingClaimRejection: Codable, Equatable, Sendable {
    case unsupportedProtocol
    case invalidClaim
    case invitationMismatch
    case expired
    case capabilityEscalation
    case invalidPublicKey
    case invalidSignature
}

public enum GuardianPairingClaimAuthentication: Codable, Equatable, Sendable {
    case authenticated(GuardianPairingClaim)
    case rejected(GuardianPairingClaimRejection)
}

public struct GuardianPairingClaimAuthenticator: Sendable {
    public init() {}

    public func sign(
        _ claim: GuardianPairingClaim,
        using privateKey: Curve25519.Signing.PrivateKey
    ) throws -> GuardianSignedPairingClaim {
        GuardianSignedPairingClaim(
            claim: claim,
            signature: try privateKey.signature(
                for: GuardianRemoteCanonicalEncoding.data(claim)
            )
        )
    }

    public func verify(
        _ signed: GuardianSignedPairingClaim,
        invitation: GuardianPairingPayload,
        now: Date
    ) throws -> GuardianPairingClaimAuthentication {
        let claim = signed.claim
        guard claim.protocolVersion == .current else {
            return .rejected(.unsupportedProtocol)
        }
        guard claim.guardianID == invitation.guardianID,
              claim.challengeNonce == invitation.challenge.nonce else {
            return .rejected(.invitationMismatch)
        }
        let knownCapabilities: UInt64 = (1 << 7) - 1
        guard claim.devicePublicKey.count == 32,
              claim.requestedCapabilities.contains(.observe),
              claim.requestedCapabilities.rawValue & ~knownCapabilities == 0,
              claim.issuedAt.timeIntervalSince1970.isFinite,
              claim.issuedAt >= invitation.issuedAt,
              claim.issuedAt <= now.addingTimeInterval(30) else {
            return .rejected(.invalidClaim)
        }
        guard invitation.challenge.expiresAt > now,
              invitation.challenge.consumedAt == nil else {
            return .rejected(.expired)
        }
        guard claim.requestedCapabilities.rawValue
            & ~invitation.allowedCapabilities.rawValue == 0 else {
            return .rejected(.capabilityEscalation)
        }
        guard let publicKey = try? Curve25519.Signing.PublicKey(
            rawRepresentation: claim.devicePublicKey
        ) else {
            return .rejected(.invalidPublicKey)
        }
        let encoded = try GuardianRemoteCanonicalEncoding.data(claim)
        guard publicKey.isValidSignature(signed.signature, for: encoded) else {
            return .rejected(.invalidSignature)
        }
        return .authenticated(claim)
    }
}

public enum GuardianRemoteCryptoError: Error, Equatable, Sendable {
    case identityMismatch
    case encodingFailed
}

enum GuardianRemoteCanonicalEncoding {
    static func data<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            return try encoder.encode(value)
        } catch {
            throw GuardianRemoteCryptoError.encodingFailed
        }
    }
}
