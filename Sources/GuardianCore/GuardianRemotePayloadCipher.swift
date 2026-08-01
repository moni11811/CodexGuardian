import CryptoKit
import Foundation

public enum GuardianRemotePayloadAlgorithm: String, Codable, Equatable, Sendable {
    case aesGCM256 = "AES.GCM.256"
}

public struct GuardianRemotePayloadBinding: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianRemoteProtocolVersion
    public let commandID: UUID
    public let deviceID: UUID
    public let expectedGeneration: Int64
    public let sequence: UInt64
    public let issuedAt: Date
    public let deadline: Date
    public let revocationEpoch: UInt64
    public let targetThreadID: String
    public let action: GuardianRemoteAction
    public let force: Bool
    public let payloadDigest: Data

    public init(command: GuardianRemoteCommand) {
        protocolVersion = command.protocolVersion
        commandID = command.commandID
        deviceID = command.deviceID
        expectedGeneration = command.expectedGeneration
        sequence = command.sequence
        issuedAt = command.issuedAt
        deadline = command.deadline
        revocationEpoch = command.revocationEpoch
        targetThreadID = command.targetThreadID
        action = command.action
        force = command.force
        payloadDigest = command.payloadDigest
    }

    public var isValid: Bool {
        protocolVersion == .current
            && expectedGeneration > 0
            && sequence > 0
            && issuedAt.timeIntervalSince1970.isFinite
            && deadline.timeIntervalSince1970.isFinite
            && deadline > issuedAt
            && !targetThreadID.isEmpty
            && !force
            && payloadDigest.count == 32
    }
}

public struct GuardianRemoteSealedPayload: Codable, Equatable, Sendable {
    public let envelopeVersion: Int
    public let algorithm: GuardianRemotePayloadAlgorithm
    public let sealedPayload: Data
    public let wrappedDEK: Data
    public let aadDigest: Data

    public init(
        envelopeVersion: Int,
        algorithm: GuardianRemotePayloadAlgorithm,
        sealedPayload: Data,
        wrappedDEK: Data,
        aadDigest: Data
    ) {
        self.envelopeVersion = envelopeVersion
        self.algorithm = algorithm
        self.sealedPayload = sealedPayload
        self.wrappedDEK = wrappedDEK
        self.aadDigest = aadDigest
    }

    public var isValid: Bool {
        envelopeVersion == 1
            && algorithm == .aesGCM256
            && !sealedPayload.isEmpty
            && !wrappedDEK.isEmpty
            && aadDigest.count == 32
    }
}

public enum GuardianRemotePayloadCipherError: Error, Equatable, Sendable {
    case invalidParentKey
    case invalidEnvelope
    case payloadDigestMismatch
}

public struct GuardianRemotePayloadCipher: Sendable {
    private let parentKey: SymmetricKey

    public init(parentKeyData: Data) throws {
        guard parentKeyData.count == 32 else {
            throw GuardianRemotePayloadCipherError.invalidParentKey
        }
        parentKey = SymmetricKey(data: parentKeyData)
    }

    public func seal(
        _ plaintext: Data,
        for command: GuardianRemoteCommand
    ) throws -> GuardianRemoteSealedPayload {
        guard Data(SHA256.hash(data: plaintext)) == command.payloadDigest else {
            throw GuardianRemotePayloadCipherError.payloadDigestMismatch
        }
        let binding = GuardianRemotePayloadBinding(command: command)
        guard binding.isValid else {
            throw GuardianRemotePayloadCipherError.invalidEnvelope
        }
        let aad = try GuardianRemoteCanonicalEncoding.data(binding)
        let aadDigest = Data(SHA256.hash(data: aad))
        let dataKey = SymmetricKey(size: .bits256)
        let dataKeyBytes = dataKey.withUnsafeBytes { Data($0) }
        guard let sealedPayload = try AES.GCM.seal(
            plaintext,
            using: dataKey,
            authenticating: aad
        ).combined,
        let wrappedDEK = try AES.GCM.seal(
            dataKeyBytes,
            using: parentKey,
            authenticating: aadDigest
        ).combined else {
            throw GuardianRemotePayloadCipherError.invalidEnvelope
        }
        return GuardianRemoteSealedPayload(
            envelopeVersion: 1,
            algorithm: .aesGCM256,
            sealedPayload: sealedPayload,
            wrappedDEK: wrappedDEK,
            aadDigest: aadDigest
        )
    }

    public func open(
        _ envelope: GuardianRemoteSealedPayload,
        for command: GuardianRemoteCommand
    ) throws -> Data {
        try open(
            envelope,
            binding: GuardianRemotePayloadBinding(command: command)
        )
    }

    public func open(
        _ envelope: GuardianRemoteSealedPayload,
        binding: GuardianRemotePayloadBinding
    ) throws -> Data {
        guard envelope.isValid else {
            throw GuardianRemotePayloadCipherError.invalidEnvelope
        }
        guard binding.isValid else {
            throw GuardianRemotePayloadCipherError.invalidEnvelope
        }
        let aad = try GuardianRemoteCanonicalEncoding.data(binding)
        let aadDigest = Data(SHA256.hash(data: aad))
        guard aadDigest == envelope.aadDigest else {
            throw GuardianRemotePayloadCipherError.invalidEnvelope
        }
        let wrappedBox = try AES.GCM.SealedBox(combined: envelope.wrappedDEK)
        let dataKeyBytes = try AES.GCM.open(
            wrappedBox,
            using: parentKey,
            authenticating: aadDigest
        )
        guard dataKeyBytes.count == 32 else {
            throw GuardianRemotePayloadCipherError.invalidEnvelope
        }
        let payloadBox = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
        let plaintext = try AES.GCM.open(
            payloadBox,
            using: SymmetricKey(data: dataKeyBytes),
            authenticating: aad
        )
        guard Data(SHA256.hash(data: plaintext)) == binding.payloadDigest else {
            throw GuardianRemotePayloadCipherError.payloadDigestMismatch
        }
        return plaintext
    }
}
