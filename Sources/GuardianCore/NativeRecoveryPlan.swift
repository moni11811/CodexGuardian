public struct NativeRecoveryPlan: Codable, Equatable, Sendable {
    public let threadID: String
    public let recoveryPrompt: String

    public init(threadID: String, recoveryPrompt: String) {
        self.threadID = threadID
        self.recoveryPrompt = recoveryPrompt
    }

    public var restartsDesktop: Bool { false }
}
