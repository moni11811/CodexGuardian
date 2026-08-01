import Foundation
import Network
import Security

public enum GuardianRemoteTLSListenerError: Error, Equatable, Sendable {
    case configurationRejected(GuardianRemoteListenerRejection)
    case identityRequired
    case certificateUnavailable
    case certificateIdentityMismatch
    case invalidPort
    case listenerCreationFailed
}

public struct GuardianRemoteTLSListenerFactory: Sendable {
    public init() {}

    public func make(
        configuration: GuardianRemoteListenerConfiguration,
        identity: SecIdentity?
    ) throws -> NWListener? {
        switch GuardianRemoteListenerPolicy().evaluate(configuration) {
        case .disabled:
            return nil
        case let .rejected(reason):
            throw GuardianRemoteTLSListenerError.configurationRejected(reason)
        case .allowed:
            break
        }
        guard let identity else {
            throw GuardianRemoteTLSListenerError.identityRequired
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            throw GuardianRemoteTLSListenerError.certificateUnavailable
        }
        let certificateDER = SecCertificateCopyData(certificate) as Data
        do {
            _ = try GuardianRemoteTLSProfileBuilder().build(
                configuration: configuration,
                certificateDER: certificateDER
            )
        } catch GuardianRemoteTLSProfileError.certificateIdentityMismatch {
            throw GuardianRemoteTLSListenerError.certificateIdentityMismatch
        } catch let GuardianRemoteTLSProfileError.configurationRejected(reason) {
            throw GuardianRemoteTLSListenerError.configurationRejected(reason)
        } catch {
            throw GuardianRemoteTLSListenerError.certificateUnavailable
        }

        guard let port = NWEndpoint.Port(rawValue: configuration.port),
              let protocolIdentity = sec_identity_create(identity) else {
            throw GuardianRemoteTLSListenerError.invalidPort
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_local_identity(
            tls.securityProtocolOptions,
            protocolIdentity
        )
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        parameters.acceptLocalOnly = configuration.bindScope == .loopback
        if let bindAddress = configuration.bindAddress {
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(bindAddress),
                port: port
            )
        }
        parameters.prohibitedInterfaceTypes = [.cellular]
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionLimit = 8
            return listener
        } catch {
            throw GuardianRemoteTLSListenerError.listenerCreationFailed
        }
    }
}
