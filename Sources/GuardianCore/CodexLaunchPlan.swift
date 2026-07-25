import Foundation

public struct CodexLaunchPlan: Equatable, Sendable {
    public let bundleIdentifier: String
    public let fallbackApplicationPaths: [String]

    public init(
        bundleIdentifier: String,
        fallbackApplicationPaths: [String] = [
            "/Applications/ChatGPT.app",
            "/Applications/Codex.app",
        ]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.fallbackApplicationPaths = fallbackApplicationPaths
    }
}
