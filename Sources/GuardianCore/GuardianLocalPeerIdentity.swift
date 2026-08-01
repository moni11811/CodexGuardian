import Foundation

public struct GuardianLocalPeerPolicy: Equatable, Sendable {
    public let role: GuardianIPCClientRole
    public let executablePath: String
    public let signingIdentifier: String
    public let teamIdentifier: String
    public let requiresHardenedRuntime: Bool

    public init(
        role: GuardianIPCClientRole,
        executablePath: String,
        signingIdentifier: String,
        teamIdentifier: String,
        requiresHardenedRuntime: Bool
    ) {
        self.role = role
        self.executablePath = Self.canonicalPath(executablePath)
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.requiresHardenedRuntime = requiresHardenedRuntime
    }

    public var isValid: Bool {
        executablePath.hasPrefix("/")
            && !signingIdentifier.isEmpty
            && !teamIdentifier.isEmpty
    }

    public func accepts(_ peer: GuardianVerifiedLocalPeer) -> Bool {
        peer.isValid
            && peer.executablePath == executablePath
            && peer.signingIdentifier == signingIdentifier
            && peer.teamIdentifier == teamIdentifier
            && (!requiresHardenedRuntime || peer.hardenedRuntime)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

public struct GuardianVerifiedLocalPeer: Equatable, Sendable {
    public let auditTokenHash: Data
    public let executablePath: String
    public let signingIdentifier: String
    public let teamIdentifier: String
    public let hardenedRuntime: Bool

    public init(
        auditTokenHash: Data,
        executablePath: String,
        signingIdentifier: String,
        teamIdentifier: String,
        hardenedRuntime: Bool
    ) {
        self.auditTokenHash = auditTokenHash
        self.executablePath = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.hardenedRuntime = hardenedRuntime
    }

    public var isValid: Bool {
        auditTokenHash.count == 32
            && executablePath.hasPrefix("/")
            && !signingIdentifier.isEmpty
            && !teamIdentifier.isEmpty
    }
}
