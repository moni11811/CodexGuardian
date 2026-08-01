import CryptoKit
import Darwin
import Foundation
import Security

public enum GuardianLocalPeerAttestationError: Error, Equatable, Sendable {
    case auditTokenUnavailable
    case executablePathUnavailable
    case codeObjectUnavailable
    case invalidCodeSignature
    case signingInformationUnavailable
}

public struct GuardianLocalPeerAttestor: Sendable {
    public init() {}

    public func inspect(descriptor: Int32) throws -> GuardianVerifiedLocalPeer {
        var auditToken = audit_token_t()
        var auditTokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        let tokenStatus = withUnsafeMutablePointer(to: &auditToken) { pointer in
            getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEERTOKEN,
                pointer,
                &auditTokenLength
            )
        }
        guard tokenStatus == 0,
              auditTokenLength == MemoryLayout<audit_token_t>.size else {
            throw GuardianLocalPeerAttestationError.auditTokenUnavailable
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        let pathLength = proc_pidpath_audittoken(
            &auditToken,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else {
            throw GuardianLocalPeerAttestationError.executablePathUnavailable
        }
        let nulIndex = pathBuffer.firstIndex(of: 0) ?? pathBuffer.endIndex
        let executablePath = String(
            decoding: pathBuffer[..<nulIndex].map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
        let auditTokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        let attributes = [
            kSecGuestAttributeAudit as String: auditTokenData as CFData,
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        ) == errSecSuccess,
        let code else {
            throw GuardianLocalPeerAttestationError.codeObjectUnavailable
        }
        let strictValidation = SecCSFlags(rawValue: 1 << 4)
        guard SecCodeCheckValidity(code, strictValidation, nil) == errSecSuccess else {
            throw GuardianLocalPeerAttestationError.invalidCodeSignature
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw GuardianLocalPeerAttestationError.signingInformationUnavailable
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: 1 << 1),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
        !signingIdentifier.isEmpty else {
            throw GuardianLocalPeerAttestationError.signingInformationUnavailable
        }
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        let codeFlags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let hardenedRuntime = codeFlags & 0x0001_0000 != 0

        return GuardianVerifiedLocalPeer(
            auditTokenHash: Data(SHA256.hash(data: auditTokenData)),
            executablePath: executablePath,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            hardenedRuntime: hardenedRuntime
        )
    }
}
