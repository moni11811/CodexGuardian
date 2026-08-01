import Foundation

public struct GuardianDaemonState: Codable, Equatable, Sendable {
    public let generation: Int64
    public let lastSequence: Int64
    public let updatedAt: Date

    public init(generation: Int64, lastSequence: Int64, updatedAt: Date) {
        self.generation = generation
        self.lastSequence = lastSequence
        self.updatedAt = updatedAt
    }
}
