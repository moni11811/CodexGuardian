import CryptoKit
import Foundation
import GuardianCore
import Testing

@Test func remoteListenerIsOffByDefault() {
    #expect(GuardianRemoteListenerPolicy().evaluate(.disabled) == .disabled)
}

@Test func remoteListenerRequiresTLS13PinnedIdentityAndPrivateScope() {
    let identityHash = Data(repeating: 0xAB, count: 32)
    let base = GuardianRemoteListenerConfiguration(
        isEnabled: true,
        bindScope: .privateNetwork,
        bindAddress: "192.168.1.20",
        port: 47_411,
        transport: .tls13(serverIdentityHash: identityHash),
        securityReviewEvidenceID: "phase7-threat-model"
    )

    #expect(GuardianRemoteListenerPolicy().evaluate(.init(
        isEnabled: base.isEnabled,
        bindScope: .privateNetwork,
        bindAddress: base.bindAddress,
        port: base.port,
        transport: .plaintext,
        securityReviewEvidenceID: base.securityReviewEvidenceID
    )) == .rejected(.tls13Required))
    #expect(GuardianRemoteListenerPolicy().evaluate(.init(
        isEnabled: base.isEnabled,
        bindScope: .allInterfaces,
        bindAddress: base.bindAddress,
        port: base.port,
        transport: base.transport,
        securityReviewEvidenceID: base.securityReviewEvidenceID
    )) == .rejected(.publicBindingForbidden))
    #expect(GuardianRemoteListenerPolicy().evaluate(.init(
        isEnabled: base.isEnabled,
        bindScope: base.bindScope,
        bindAddress: base.bindAddress,
        port: base.port,
        transport: .tls13(serverIdentityHash: Data(repeating: 1, count: 31)),
        securityReviewEvidenceID: base.securityReviewEvidenceID
    )) == .rejected(.invalidServerIdentity))
    #expect(GuardianRemoteListenerPolicy().evaluate(.init(
        isEnabled: base.isEnabled,
        bindScope: base.bindScope,
        bindAddress: base.bindAddress,
        port: base.port,
        transport: base.transport,
        securityReviewEvidenceID: ""
    )) == .rejected(.securityReviewRequired))
    #expect(GuardianRemoteListenerPolicy().evaluate(base) == .allowed)
}

@Test func remotePushPayloadCanCarryOnlyOpaqueWakeIdentity() throws {
    let wake = GuardianRemotePushWake(
        protocolVersion: .current,
        incidentID: UUID(),
        nonce: UUID()
    )
    let data = try JSONEncoder().encode(wake)
    let text = String(decoding: data, as: UTF8.self)

    #expect(!text.contains("prompt"))
    #expect(!text.contains("thread"))
    #expect(!text.contains("path"))
    #expect(!text.contains("diff"))
    #expect(try JSONDecoder().decode(GuardianRemotePushWake.self, from: data) == wake)
}

@Test func privateNetworkGateRejectsPublicPeersIncludingDocumentationRanges() {
    let policy = GuardianRemotePeerAddressPolicy()

    #expect(policy.evaluate("127.0.0.1") == .allowed(.loopback))
    #expect(policy.evaluate("10.4.5.6") == .allowed(.privateNetwork))
    #expect(policy.evaluate("192.168.1.8") == .allowed(.privateNetwork))
    #expect(policy.evaluate("100.99.1.2") == .allowed(.privateNetwork))
    #expect(policy.evaluate("fd12:3456::1") == .allowed(.privateNetwork))
    #expect(policy.evaluate("8.8.8.8") == .rejected(.publicAddress))
    #expect(policy.evaluate("203.0.113.10") == .rejected(.publicAddress))
    #expect(policy.evaluate("guardian.example") == .rejected(.unresolvedAddress))
}

@Test func privateNetworkListenerWithoutExactBindAddressFailsClosed() {
    let configuration = GuardianRemoteListenerConfiguration(
        isEnabled: true,
        bindScope: .privateNetwork,
        port: 47_411,
        transport: .tls13(serverIdentityHash: Data(repeating: 0xAB, count: 32)),
        securityReviewEvidenceID: "phase7-threat-model"
    )

    #expect(GuardianRemoteListenerPolicy().evaluate(configuration)
        == .rejected(.bindAddressRequired))
    #expect(GuardianRemoteListenerPolicy().evaluate(.init(
        isEnabled: true,
        bindScope: .privateNetwork,
        bindAddress: "203.0.113.9",
        port: configuration.port,
        transport: configuration.transport,
        securityReviewEvidenceID: configuration.securityReviewEvidenceID
    )) == .rejected(.bindAddressScopeMismatch))
}

@Test func tlsProfilePinsCertificateAndEnforcesTLS13Only() throws {
    let certificateDER = Data("guardian-certificate-der".utf8)
    let certificateHash = Data(SHA256.hash(data: certificateDER))
    let configuration = GuardianRemoteListenerConfiguration(
        isEnabled: true,
        bindScope: .privateNetwork,
        bindAddress: "192.168.1.20",
        port: 47_411,
        transport: .tls13(serverIdentityHash: certificateHash),
        securityReviewEvidenceID: "phase7-threat-model"
    )

    let profile = try GuardianRemoteTLSProfileBuilder().build(
        configuration: configuration,
        certificateDER: certificateDER
    )
    #expect(profile.minimumVersion == .tls13)
    #expect(profile.maximumVersion == .tls13)
    #expect(profile.certificateHash == certificateHash)

    #expect(throws: GuardianRemoteTLSProfileError.certificateIdentityMismatch) {
        try GuardianRemoteTLSProfileBuilder().build(
            configuration: configuration,
            certificateDER: Data("attacker-certificate".utf8)
        )
    }
}

@Test func concreteTLSListenerFactoryFailsClosedWithoutServerIdentity() throws {
    #expect(try GuardianRemoteTLSListenerFactory().make(
        configuration: .disabled,
        identity: nil
    ) == nil)

    let enabled = GuardianRemoteListenerConfiguration(
        isEnabled: true,
        bindScope: .privateNetwork,
        bindAddress: "192.168.1.20",
        port: 47_411,
        transport: .tls13(serverIdentityHash: Data(repeating: 0xA1, count: 32)),
        securityReviewEvidenceID: "phase7-threat-model"
    )
    #expect(throws: GuardianRemoteTLSListenerError.identityRequired) {
        try GuardianRemoteTLSListenerFactory().make(
            configuration: enabled,
            identity: nil
        )
    }
}

@Test func tlsConnectionServerRequiresConcreteValidatedListener() {
    let handler = GuardianRemoteConnectionHandler(
        rateLimitPolicy: .init(
            maximumRequests: 10,
            requestWindow: 10,
            maximumAuthenticationFailures: 2,
            authenticationLockout: 30
        ),
        route: { request, _, _ in
            GuardianRemoteWireResponse(
                protocolVersion: .current,
                requestID: request.requestID,
                body: .rejected(.serverUnavailable)
            )
        }
    )

    #expect(throws: GuardianRemoteTLSServerError.listenerRequired) {
        try GuardianRemoteTLSConnectionServer(
            listener: nil,
            handler: handler,
            generationProvider: { 1 }
        )
    }
}
