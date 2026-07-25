import Foundation

public struct CodexThreadDeepLink: Equatable, Sendable {
    public let url: URL

    public init(threadID: String) {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(threadID)"
        url = components.url!
    }
}
