import Foundation

public enum GuardianPairingCoordinatorError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invitationRejected(GuardianPairingAuthenticationRejection)
    case claimRejected(GuardianPairingClaimRejection)
}

public actor GuardianPairingCoordinator {
    private let journal: GuardianJournal
    private let guardianID: UUID
    private let identityKeyManager: GuardianRemoteIdentityKeyManager

    public init(
        journal: GuardianJournal,
        guardianID: UUID,
        identityKeyManager: GuardianRemoteIdentityKeyManager
    ) {
        self.journal = journal
        self.guardianID = guardianID
        self.identityKeyManager = identityKeyManager
    }

    public func issueInvitation(
        endpointHost: String,
        endpointPort: UInt16,
        tlsCertificateHash: Data,
        allowedCapabilities: GuardianRemoteCapabilities,
        lifetime: TimeInterval = 60,
        now: Date = Date()
    ) async throws -> GuardianSignedPairingPayload {
        let knownCapabilities: UInt64 = (1 << 7) - 1
        guard endpointPort > 0,
              tlsCertificateHash.count == 32,
              allowedCapabilities.contains(.observe),
              allowedCapabilities.rawValue & ~knownCapabilities == 0,
              (10...300).contains(lifetime),
              lifetime.isFinite,
              now.timeIntervalSince1970.isFinite else {
            throw GuardianPairingCoordinatorError.invalidConfiguration
        }
        guard case .allowed = GuardianRemotePeerAddressPolicy().evaluate(endpointHost) else {
            throw GuardianPairingCoordinatorError.invalidConfiguration
        }
        let signingKey = try await identityKeyManager.loadOrCreateSigningKey()
        let identity = try await identityKeyManager.loadOrCreate()
        let challenge = GuardianPairingChallenge(
            nonce: UUID(),
            guardianIdentityHash: identity.identityHash,
            expiresAt: now.addingTimeInterval(lifetime),
            consumedAt: nil
        )
        try journal.issuePairingChallenge(challenge, issuedAt: now)
        let payload = GuardianPairingPayload(
            protocolVersion: .current,
            guardianID: guardianID,
            guardianPublicKey: identity.publicKey,
            tlsCertificateHash: tlsCertificateHash,
            endpointHost: endpointHost,
            endpointPort: endpointPort,
            challenge: challenge,
            allowedCapabilities: allowedCapabilities,
            issuedAt: now
        )
        return try GuardianPairingAuthenticator().sign(payload, using: signingKey)
    }

    public func completePairing(
        invitation: GuardianSignedPairingPayload,
        claim: GuardianSignedPairingClaim,
        now: Date = Date()
    ) async throws -> GuardianRemoteDevice {
        let identity = try await identityKeyManager.loadOrCreate()
        let invitationPayload: GuardianPairingPayload
        switch try GuardianPairingAuthenticator().verify(
            invitation,
            expectedIdentityHash: identity.identityHash,
            now: now
        ) {
        case let .authenticated(payload):
            guard payload.guardianID == guardianID else {
                throw GuardianPairingCoordinatorError.invalidConfiguration
            }
            invitationPayload = payload
        case let .rejected(reason):
            try journal.recordPairingRejection(
                deviceID: claim.claim.deviceID,
                reason: Self.auditReason(for: reason),
                at: now
            )
            throw GuardianPairingCoordinatorError.invitationRejected(reason)
        }
        let authenticatedClaim: GuardianPairingClaim
        switch try GuardianPairingClaimAuthenticator().verify(
            claim,
            invitation: invitationPayload,
            now: now
        ) {
        case let .authenticated(value):
            authenticatedClaim = value
        case let .rejected(reason):
            try journal.recordPairingRejection(
                deviceID: claim.claim.deviceID,
                reason: Self.auditReason(for: reason),
                at: now
            )
            throw GuardianPairingCoordinatorError.claimRejected(reason)
        }
        let device = GuardianRemoteDevice(
            id: authenticatedClaim.deviceID,
            publicKey: authenticatedClaim.devicePublicKey,
            capabilities: authenticatedClaim.requestedCapabilities,
            status: .active,
            pairingEpoch: 1,
            revocationEpoch: 0,
            lastAcceptedSequence: 0,
            pairedAt: now,
            lastSeenAt: nil
        )
        try journal.pairRemoteDevice(
            device,
            challenge: invitationPayload.challenge,
            at: now
        )
        return device
    }

    private static func auditReason(
        for reason: GuardianPairingAuthenticationRejection
    ) -> GuardianPairingAuditRejection {
        switch reason {
        case .unsupportedProtocol: .invitationUnsupportedProtocol
        case .invalidPayload: .invitationInvalidPayload
        case .identityMismatch: .invitationIdentityMismatch
        case .expired: .invitationExpired
        case .alreadyConsumed: .invitationAlreadyConsumed
        case .invalidSignature: .invitationInvalidSignature
        }
    }

    private static func auditReason(
        for reason: GuardianPairingClaimRejection
    ) -> GuardianPairingAuditRejection {
        switch reason {
        case .unsupportedProtocol: .claimUnsupportedProtocol
        case .invalidClaim: .claimInvalid
        case .invitationMismatch: .claimInvitationMismatch
        case .expired: .claimExpired
        case .capabilityEscalation: .claimCapabilityEscalation
        case .invalidPublicKey: .claimInvalidPublicKey
        case .invalidSignature: .claimInvalidSignature
        }
    }
}

public actor GuardianRemotePairingCompletion {
    private let journal: GuardianJournal
    private let identityKeyManager: GuardianRemoteIdentityKeyManager

    public init(
        journal: GuardianJournal,
        identityKeyManager: GuardianRemoteIdentityKeyManager = GuardianRemoteIdentityKeyManager()
    ) {
        self.journal = journal
        self.identityKeyManager = identityKeyManager
    }

    public func complete(
        _ request: GuardianRemotePairingRequest,
        now: Date = Date()
    ) async throws -> GuardianRemotePairingReceipt {
        let coordinator = GuardianPairingCoordinator(
            journal: journal,
            guardianID: request.invitation.payload.guardianID,
            identityKeyManager: identityKeyManager
        )
        let device = try await coordinator.completePairing(
            invitation: request.invitation,
            claim: request.claim,
            now: now
        )
        return GuardianRemotePairingReceipt(
            deviceID: device.id,
            capabilities: device.capabilities,
            pairingEpoch: device.pairingEpoch,
            revocationEpoch: device.revocationEpoch,
            pairedAt: device.pairedAt
        )
    }
}
