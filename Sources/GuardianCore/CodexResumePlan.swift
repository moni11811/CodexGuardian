public struct CodexResumePlan: Equatable, Sendable {
    public let arguments: [String]
    public let usesDetachedCLI: Bool

    public init(request: RestartRequest) {
        arguments = []
        usesDetachedCLI = false
    }
}
