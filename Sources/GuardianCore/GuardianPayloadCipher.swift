import CryptoKit
import Foundation

public enum GuardianPayloadCipherError: Error, Equatable, Sendable {
    case invalidParentKey
    case invalidEnvelope
}

private struct GuardianSealedEnvelope: Codable {
    let version: Int
    let wrappedOperationKey: Data
    let sealedPayload: Data
}

public struct GuardianPayloadCipher: Sendable {
    private let parentKey: SymmetricKey

    public init(parentKeyData: Data) throws {
        guard parentKeyData.count == 32 else {
            throw GuardianPayloadCipherError.invalidParentKey
        }
        parentKey = SymmetricKey(data: parentKeyData)
    }

    public func seal(_ plaintext: Data, for operationID: UUID) throws -> Data {
        let operationKey = SymmetricKey(size: .bits256)
        let operationKeyData = operationKey.withUnsafeBytes { Data($0) }
        let authenticatedData = Data(operationID.uuidString.utf8)
        guard let wrappedKey = try AES.GCM.seal(
            operationKeyData,
            using: parentKey,
            authenticating: authenticatedData
        ).combined,
        let payload = try AES.GCM.seal(
            plaintext,
            using: operationKey,
            authenticating: authenticatedData
        ).combined else {
            throw GuardianPayloadCipherError.invalidEnvelope
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(GuardianSealedEnvelope(
            version: 1,
            wrappedOperationKey: wrappedKey,
            sealedPayload: payload
        ))
    }

    public func open(_ envelopeData: Data, for operationID: UUID) throws -> Data {
        let envelope = try JSONDecoder().decode(
            GuardianSealedEnvelope.self,
            from: envelopeData
        )
        guard envelope.version == 1 else {
            throw GuardianPayloadCipherError.invalidEnvelope
        }
        let authenticatedData = Data(operationID.uuidString.utf8)
        let wrappedBox = try AES.GCM.SealedBox(combined: envelope.wrappedOperationKey)
        let operationKeyData = try AES.GCM.open(
            wrappedBox,
            using: parentKey,
            authenticating: authenticatedData
        )
        guard operationKeyData.count == 32 else {
            throw GuardianPayloadCipherError.invalidEnvelope
        }
        let payloadBox = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
        return try AES.GCM.open(
            payloadBox,
            using: SymmetricKey(data: operationKeyData),
            authenticating: authenticatedData
        )
    }
}
