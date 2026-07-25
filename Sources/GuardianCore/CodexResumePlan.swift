public struct CodexResumePlan: Equatable, Sendable {
    public let arguments: [String]

    public init(request: RestartRequest) {
        arguments = [
            "exec", "resume", "--json",
            request.threadID,
            request.recoveryPrompt,
        ]
    }
}
