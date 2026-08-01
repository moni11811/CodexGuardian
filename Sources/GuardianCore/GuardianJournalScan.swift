import Foundation

public enum GuardianQuarantineReason: String, Codable, Equatable, Sendable {
    case invalidRecord
}

public struct GuardianQuarantinedRow: Codable, Equatable, Sendable {
    public let table: String
    public let primaryKey: String
    public let reason: GuardianQuarantineReason

    public init(
        table: String,
        primaryKey: String,
        reason: GuardianQuarantineReason
    ) {
        self.table = table
        self.primaryKey = primaryKey
        self.reason = reason
    }
}

public struct GuardianJournalScan<Item: Sendable>: Sendable {
    public let items: [Item]
    public let quarantined: [GuardianQuarantinedRow]

    public init(items: [Item], quarantined: [GuardianQuarantinedRow]) {
        self.items = items
        self.quarantined = quarantined
    }
}

extension GuardianJournalScan: Equatable where Item: Equatable {}
