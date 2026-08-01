import Network
import Security

public enum GuardianRemoteServiceBootstrapError: Error, Equatable, Sendable {
    case invalidConfiguration(GuardianRemoteServiceConfigurationRejection)
    case identityLabelMissing
    case listenerUnavailable
}

public struct GuardianRemoteServiceBootstrap {
    public typealias IdentityLoader = (String) throws -> SecIdentity
    public typealias ListenerFactory = (
        GuardianRemoteListenerConfiguration,
        SecIdentity
    ) throws -> NWListener?

    public init() {}

    public func make(
        configuration: GuardianRemoteServiceConfiguration,
        journal: GuardianJournal,
        runtime: GuardianDaemonRuntime,
        identityLoader: IdentityLoader = {
            try GuardianRemoteTLSIdentityLocator().load(label: $0)
        },
        listenerFactory: ListenerFactory = {
            try GuardianRemoteTLSListenerFactory().make(
                configuration: $0,
                identity: $1
            )
        }
    ) throws -> GuardianRemoteTLSConnectionServer? {
        switch configuration.validation {
        case .disabled:
            return nil
        case let .rejected(reason):
            throw GuardianRemoteServiceBootstrapError.invalidConfiguration(reason)
        case .allowed:
            break
        }
        guard let identityLabel = configuration.identityLabel else {
            throw GuardianRemoteServiceBootstrapError.identityLabelMissing
        }
        let identity = try identityLoader(identityLabel)
        guard let listener = try listenerFactory(configuration.listener, identity) else {
            throw GuardianRemoteServiceBootstrapError.listenerUnavailable
        }
        let payloadKeyManager = GuardianParentKeyManager(
            service: "com.moni.codexguardian.remote-payload-parent-key"
        )
        let gateway = GuardianRemoteGatewayCore(
            journal: journal,
            payloadSealer: { command, payload in
                let parentKey = try await payloadKeyManager.loadOrCreate()
                return try GuardianRemotePayloadCipher(
                    parentKeyData: parentKey
                ).seal(payload, for: command)
            }
        )
        let pairingCompletion = GuardianRemotePairingCompletion(journal: journal)
        let router = GuardianRemoteRequestRouter(
            gateway: gateway,
            snapshotProvider: { try await runtime.currentSnapshot() },
            eventReplayProvider: { cursor, limit in
                try journal.replayDaemonEvents(after: cursor, limit: limit)
            },
            pairingHandler: { request, now in
                try await pairingCompletion.complete(request, now: now)
            }
        )
        let handler = GuardianRemoteConnectionHandler(
            router: router,
            rateLimitPolicy: configuration.rateLimitPolicy
        )
        return try GuardianRemoteTLSConnectionServer(
            listener: listener,
            handler: handler,
            generationProvider: { runtime.generation }
        )
    }
}
