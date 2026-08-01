import Foundation

public struct GuardianDesktopProcessIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let bundleURLPath: String
    public let signingIdentifier: String
    public let teamIdentifier: String?
    public let processID: Int32
    public let processStartIdentity: UInt64
    public let serverGeneration: Int64

    public init(
        bundleIdentifier: String,
        bundleURLPath: String,
        signingIdentifier: String,
        teamIdentifier: String?,
        processID: Int32,
        processStartIdentity: UInt64,
        serverGeneration: Int64
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleURLPath = bundleURLPath
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.processID = processID
        self.processStartIdentity = processStartIdentity
        self.serverGeneration = serverGeneration
    }
}

public enum GuardianRestartIssueDisposition: Equatable, Sendable {
    case newlyIssued
    case resumePreviouslyIssued
}

enum GuardianRestartFenceIntegerCodec {
    static func decodeProcessID(_ stored: Int64) throws -> Int32 {
        guard stored > 0, let value = Int32(exactly: stored) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        return value
    }

    static func decodeProcessStartIdentity(_ stored: Int64) throws -> UInt64 {
        guard stored > 0 else {
            throw GuardianJournalError.corruptStoredOperation
        }
        return UInt64(stored)
    }

    static func encodeProcessStartIdentity(_ value: UInt64) throws -> Int64 {
        guard value > 0, let stored = Int64(exactly: value) else {
            throw GuardianJournalError.corruptStoredOperation
        }
        return stored
    }

    static func validate(_ identity: GuardianDesktopProcessIdentity) throws {
        guard !identity.bundleIdentifier.isEmpty,
              !identity.bundleURLPath.isEmpty,
              identity.bundleURLPath.hasPrefix("/"),
              !identity.signingIdentifier.isEmpty,
              identity.teamIdentifier?.isEmpty != true,
              identity.processID > 0,
              identity.processStartIdentity > 0,
              identity.processStartIdentity <= UInt64(Int64.max),
              identity.serverGeneration > 0 else {
            throw GuardianJournalError.corruptStoredOperation
        }
    }
}
