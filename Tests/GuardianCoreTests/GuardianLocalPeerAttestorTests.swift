import Darwin
import Foundation
import GuardianCore
import Testing

@Test func localPeerAttestorRejectsMissingAuditTokenWithoutPIDFallback() {
    #expect(throws: GuardianLocalPeerAttestationError.auditTokenUnavailable) {
        try GuardianLocalPeerAttestor().inspect(descriptor: -1)
    }
}

@Test func localPeerAttestorBindsEvidenceToUnixPeerAuditToken() throws {
    var descriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    defer {
        if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
        if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
    }

    let peer = try GuardianLocalPeerAttestor().inspect(descriptor: descriptors[0])

    #expect(peer.auditTokenHash.count == 32)
    #expect(peer.executablePath.hasPrefix("/"))
    #expect(!peer.signingIdentifier.isEmpty)
}
