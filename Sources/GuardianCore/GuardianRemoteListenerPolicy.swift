import Foundation
import Darwin
import CryptoKit

public enum GuardianRemoteBindScope: String, Codable, Equatable, Sendable {
    case loopback
    case privateNetwork
    case allInterfaces
    case publicNetwork
}

public enum GuardianRemoteTransportSecurity: Codable, Equatable, Sendable {
    case plaintext
    case tls13(serverIdentityHash: Data)
}

public struct GuardianRemoteListenerConfiguration: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let bindScope: GuardianRemoteBindScope
    public let bindAddress: String?
    public let port: UInt16
    public let transport: GuardianRemoteTransportSecurity
    public let securityReviewEvidenceID: String

    public init(
        isEnabled: Bool,
        bindScope: GuardianRemoteBindScope,
        bindAddress: String? = nil,
        port: UInt16,
        transport: GuardianRemoteTransportSecurity,
        securityReviewEvidenceID: String
    ) {
        self.isEnabled = isEnabled
        self.bindScope = bindScope
        self.bindAddress = bindAddress
        self.port = port
        self.transport = transport
        self.securityReviewEvidenceID = securityReviewEvidenceID
    }

    public static let disabled = GuardianRemoteListenerConfiguration(
        isEnabled: false,
        bindScope: .loopback,
        bindAddress: nil,
        port: 0,
        transport: .plaintext,
        securityReviewEvidenceID: ""
    )
}

public enum GuardianRemoteListenerRejection: Codable, Equatable, Sendable {
    case invalidPort
    case bindAddressRequired
    case bindAddressScopeMismatch
    case tls13Required
    case invalidServerIdentity
    case publicBindingForbidden
    case securityReviewRequired
}

public enum GuardianRemoteListenerDecision: Codable, Equatable, Sendable {
    case disabled
    case allowed
    case rejected(GuardianRemoteListenerRejection)
}

public struct GuardianRemoteListenerPolicy: Sendable {
    public init() {}

    public func evaluate(
        _ configuration: GuardianRemoteListenerConfiguration
    ) -> GuardianRemoteListenerDecision {
        guard configuration.isEnabled else { return .disabled }
        guard configuration.port > 0 else { return .rejected(.invalidPort) }
        switch configuration.bindScope {
        case .loopback:
            if let address = configuration.bindAddress {
                guard GuardianRemotePeerAddressPolicy().evaluate(address)
                    == .allowed(.loopback) else {
                    return .rejected(.bindAddressScopeMismatch)
                }
            }
        case .privateNetwork:
            guard let address = configuration.bindAddress,
                  GuardianRemotePeerAddressPolicy().evaluate(address)
                    == .allowed(.privateNetwork) else {
                return configuration.bindAddress == nil
                    ? .rejected(.bindAddressRequired)
                    : .rejected(.bindAddressScopeMismatch)
            }
        case .allInterfaces, .publicNetwork:
            return .rejected(.publicBindingForbidden)
        }
        switch configuration.transport {
        case .plaintext:
            return .rejected(.tls13Required)
        case let .tls13(serverIdentityHash):
            guard serverIdentityHash.count == 32 else {
                return .rejected(.invalidServerIdentity)
            }
        }
        guard !configuration.securityReviewEvidenceID
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.securityReviewRequired)
        }
        return .allowed
    }
}

public enum GuardianRemoteTLSVersion: String, Codable, Equatable, Sendable {
    case tls13
}

public struct GuardianRemoteTLSProfile: Codable, Equatable, Sendable {
    public let minimumVersion: GuardianRemoteTLSVersion
    public let maximumVersion: GuardianRemoteTLSVersion
    public let certificateHash: Data

    public init(
        minimumVersion: GuardianRemoteTLSVersion,
        maximumVersion: GuardianRemoteTLSVersion,
        certificateHash: Data
    ) {
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
        self.certificateHash = certificateHash
    }
}

public enum GuardianRemoteTLSProfileError: Error, Equatable, Sendable {
    case configurationRejected(GuardianRemoteListenerRejection)
    case invalidCertificate
    case certificateIdentityMismatch
}

public struct GuardianRemoteTLSProfileBuilder: Sendable {
    public init() {}

    public func build(
        configuration: GuardianRemoteListenerConfiguration,
        certificateDER: Data
    ) throws -> GuardianRemoteTLSProfile {
        switch GuardianRemoteListenerPolicy().evaluate(configuration) {
        case .disabled:
            throw GuardianRemoteTLSProfileError.configurationRejected(.tls13Required)
        case let .rejected(reason):
            throw GuardianRemoteTLSProfileError.configurationRejected(reason)
        case .allowed:
            break
        }
        guard !certificateDER.isEmpty else {
            throw GuardianRemoteTLSProfileError.invalidCertificate
        }
        guard case let .tls13(expectedHash) = configuration.transport else {
            throw GuardianRemoteTLSProfileError.configurationRejected(.tls13Required)
        }
        let actualHash = Data(SHA256.hash(data: certificateDER))
        guard actualHash == expectedHash else {
            throw GuardianRemoteTLSProfileError.certificateIdentityMismatch
        }
        return GuardianRemoteTLSProfile(
            minimumVersion: .tls13,
            maximumVersion: .tls13,
            certificateHash: actualHash
        )
    }
}

public struct GuardianRemotePushWake: Codable, Equatable, Sendable {
    public let protocolVersion: GuardianRemoteProtocolVersion
    public let incidentID: UUID
    public let nonce: UUID

    public init(
        protocolVersion: GuardianRemoteProtocolVersion,
        incidentID: UUID,
        nonce: UUID
    ) {
        self.protocolVersion = protocolVersion
        self.incidentID = incidentID
        self.nonce = nonce
    }
}

public enum GuardianRemotePeerScope: Codable, Equatable, Sendable {
    case loopback
    case privateNetwork
}

public enum GuardianRemotePeerRejection: Codable, Equatable, Sendable {
    case unresolvedAddress
    case publicAddress
}

public enum GuardianRemotePeerDecision: Codable, Equatable, Sendable {
    case allowed(GuardianRemotePeerScope)
    case rejected(GuardianRemotePeerRejection)
}

public struct GuardianRemotePeerAddressPolicy: Sendable {
    public init() {}

    public func evaluate(_ address: String) -> GuardianRemotePeerDecision {
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let octets = [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff),
            ]
            return evaluateIPv4(octets)
        }

        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return evaluateIPv6(bytes)
        }
        return .rejected(.unresolvedAddress)
    }

    private func evaluateIPv4(_ bytes: [UInt8]) -> GuardianRemotePeerDecision {
        guard bytes.count == 4 else { return .rejected(.unresolvedAddress) }
        if bytes[0] == 127 { return .allowed(.loopback) }
        let isPrivate = bytes[0] == 10
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 100 && (64...127).contains(bytes[1]))
            || (bytes[0] == 169 && bytes[1] == 254)
        return isPrivate ? .allowed(.privateNetwork) : .rejected(.publicAddress)
    }

    private func evaluateIPv6(_ bytes: [UInt8]) -> GuardianRemotePeerDecision {
        guard bytes.count == 16 else { return .rejected(.unresolvedAddress) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
            return .allowed(.loopback)
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }),
           bytes[10] == 0xff,
           bytes[11] == 0xff {
            return evaluateIPv4(Array(bytes.suffix(4)))
        }
        let isPrivate = bytes[0] & 0xfe == 0xfc
            || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        return isPrivate ? .allowed(.privateNetwork) : .rejected(.publicAddress)
    }
}
