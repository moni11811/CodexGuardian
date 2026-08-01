import CryptoKit
import Foundation
import GuardianCore

func guardianTestSealedPayload(seed: UInt8 = 0xA5) -> GuardianRemoteSealedPayload {
    GuardianRemoteSealedPayload(
        envelopeVersion: 1,
        algorithm: .aesGCM256,
        sealedPayload: Data([seed]),
        wrappedDEK: Data([seed ^ 0xFF]),
        aadDigest: Data(repeating: seed, count: 32)
    )
}

func guardianTestPayloadSealer(
    command: GuardianRemoteCommand,
    payload: Data
) throws -> GuardianRemoteSealedPayload {
    try GuardianRemotePayloadCipher(
        parentKeyData: Data(repeating: 0x5A, count: 32)
    ).seal(payload, for: command)
}
