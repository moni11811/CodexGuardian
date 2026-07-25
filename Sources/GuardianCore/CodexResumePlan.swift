public struct CodexResumePlan: Equatable, Sendable {
    public let arguments: [String]

    public init(request: RestartRequest) {
        arguments = [
            "exec", "--skip-git-repo-check", "resume", "--json",
            request.threadID,
            request.recoveryPrompt,
        ]
    }
}
