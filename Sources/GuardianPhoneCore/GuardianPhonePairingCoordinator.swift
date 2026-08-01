import Foundation

public struct PhonePinnedEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let tlsCertificateHash: Data

    public init(host: String, port: UInt16, tlsCertificateHash: Data) {
        self.host = host
        self.port = port
        self.tlsCertificateHash = tlsCertificateHash
    }

    public var isValid: Bool {
        PhonePrivateEndpointPolicy.allows(host)
            && port > 0
            && tlsCertificateHash.count == 32
    }
}

public struct PhonePairedGuardian: Codable, Equatable, Sendable {
    public let guardianID: UUID
    public let guardianPublicKey: Data
    public let deviceID: UUID
    public let endpoint: PhonePinnedEndpoint
    public let capabilities: Set<PhoneAction>
    public let pairingEpoch: UInt64
    public let revocationEpoch: UInt64
    public let pairedAt: Date

    public init(
        guardianID: UUID,
        guardianPublicKey: Data,
        deviceID: UUID,
        endpoint: PhonePinnedEndpoint,
        capabilities: Set<PhoneAction>,
        pairingEpoch: UInt64,
        revocationEpoch: UInt64,
        pairedAt: Date
    ) {
        self.guardianID = guardianID
        self.guardianPublicKey = guardianPublicKey
        self.deviceID = deviceID
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.pairingEpoch = pairingEpoch
        self.revocationEpoch = revocationEpoch
        self.pairedAt = pairedAt
    }
}

public protocol PhonePairingStorage: Sendable {
    func loadOrCreateIdentity() async throws -> PhoneDeviceIdentity
    func loadPairing() async throws -> PhonePairedGuardian?
    func save(_ pairing: PhonePairedGuardian) async throws
}

public extension PhonePairingStorage {
    func loadPairing() async throws -> PhonePairedGuardian? { nil }
}

public enum PhonePairingCoordinatorError: Error, Equatable, Sendable {
    case invalidEndpoint
    case receiptDeviceMismatch
    case receiptCapabilityMismatch
    case invalidReceipt
}

public struct PhonePairingCoordinator: Sendable {
    public typealias Exchange = @Sendable (
        PhonePinnedEndpoint,
        Data
    ) async throws -> Data

    private let storage: any PhonePairingStorage
    private let exchange: Exchange

    public init(
        storage: any PhonePairingStorage,
        exchange: @escaping Exchange
    ) {
        self.storage = storage
        self.exchange = exchange
    }

    public func pair(
        code: String,
        requestedActions: Set<PhoneAction>,
        now: Date = Date()
    ) async throws -> PhonePairedGuardian {
        let invitation = try PhonePairingCodeDecoder().decode(code, now: now)
        let endpoint = PhonePinnedEndpoint(
            host: invitation.endpointHost,
            port: invitation.endpointPort,
            tlsCertificateHash: invitation.tlsCertificateHash
        )
        guard endpoint.isValid else { throw PhonePairingCoordinatorError.invalidEndpoint }
        let identity = try await storage.loadOrCreateIdentity()
        let pending = try PhoneRemotePairingWireCodec().makeRequest(
            invitation: invitation,
            identity: identity,
            requestedActions: requestedActions,
            now: now
        )
        let responseFrame = try await exchange(endpoint, pending.frame)
        let receipt = try PhoneRemotePairingWireCodec().decodeResponse(
            responseFrame,
            expectedRequestID: pending.requestID
        )
        guard receipt.deviceID == identity.deviceID else {
            throw PhonePairingCoordinatorError.receiptDeviceMismatch
        }
        let expectedCapabilities = PhoneRemotePairingWireCodec.normalizedActions(
            for: requestedActions
        )
        guard receipt.capabilities == expectedCapabilities else {
            throw PhonePairingCoordinatorError.receiptCapabilityMismatch
        }
        guard receipt.pairingEpoch > 0,
              receipt.pairedAt.timeIntervalSince1970.isFinite else {
            throw PhonePairingCoordinatorError.invalidReceipt
        }
        let pairing = PhonePairedGuardian(
            guardianID: invitation.guardianID,
            guardianPublicKey: invitation.guardianPublicKey,
            deviceID: receipt.deviceID,
            endpoint: endpoint,
            capabilities: receipt.capabilities,
            pairingEpoch: receipt.pairingEpoch,
            revocationEpoch: receipt.revocationEpoch,
            pairedAt: receipt.pairedAt
        )
        try await storage.save(pairing)
        return pairing
    }
}
