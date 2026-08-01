public struct CodexDesktopControlEvidence: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case stdio
        case unixSocket
        case unknown
    }

    public enum Inventory: Equatable, Sendable {
        case complete
        case partial
        case unavailable
    }

    public let desktopProcessID: Int32
    public let appServerProcessID: Int32?
    public let appServerParentProcessID: Int32?
    public let transport: Transport
    public let socketOwnerProcessID: Int32?
    public let schemaSupported: Bool
    public let inventory: Inventory
    public let desktopUISynchronizationProven: Bool
    public let correlatedMessagePersistenceProven: Bool

    public init(
        desktopProcessID: Int32,
        appServerProcessID: Int32?,
        appServerParentProcessID: Int32?,
        transport: Transport,
        socketOwnerProcessID: Int32?,
        schemaSupported: Bool,
        inventory: Inventory,
        desktopUISynchronizationProven: Bool,
        correlatedMessagePersistenceProven: Bool
    ) {
        self.desktopProcessID = desktopProcessID
        self.appServerProcessID = appServerProcessID
        self.appServerParentProcessID = appServerParentProcessID
        self.transport = transport
        self.socketOwnerProcessID = socketOwnerProcessID
        self.schemaSupported = schemaSupported
        self.inventory = inventory
        self.desktopUISynchronizationProven = desktopUISynchronizationProven
        self.correlatedMessagePersistenceProven = correlatedMessagePersistenceProven
    }
}

public enum CodexDesktopControlUnavailableReason: Equatable, Sendable {
    case appServerMissing
    case appServerIsNotDesktopChild
    case noSupportedControlListener
    case socketOwnerMismatch
    case unsupportedSchema
}

public enum CodexDesktopControlMode: Equatable, Sendable {
    case unavailable(CodexDesktopControlUnavailableReason)
    case observeOnly
    case readWrite
}

public struct CodexDesktopControlPolicy: Sendable {
    public init() {}

    public func mode(
        for evidence: CodexDesktopControlEvidence
    ) -> CodexDesktopControlMode {
        guard let appServerProcessID = evidence.appServerProcessID else {
            return .unavailable(.appServerMissing)
        }
        guard evidence.appServerParentProcessID == evidence.desktopProcessID else {
            return .unavailable(.appServerIsNotDesktopChild)
        }
        guard evidence.transport == .unixSocket else {
            return .unavailable(.noSupportedControlListener)
        }
        guard evidence.socketOwnerProcessID == appServerProcessID else {
            return .unavailable(.socketOwnerMismatch)
        }
        guard evidence.schemaSupported else {
            return .unavailable(.unsupportedSchema)
        }
        guard evidence.inventory == .complete,
              evidence.desktopUISynchronizationProven,
              evidence.correlatedMessagePersistenceProven else {
            return .observeOnly
        }
        return .readWrite
    }
}
