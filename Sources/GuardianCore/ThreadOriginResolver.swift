import Foundation

public enum ThreadOriginResolverError: LocalizedError {
    case invalidToken
    case originNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "origin_token must be a UUID unique to this restart call"
        case .originNotFound: "Could not prove which Codex thread requested recovery"
        }
    }
}

public struct ThreadOriginResolver: Sendable {
    public let sessionsRoot: URL

    public init(sessionsRoot: URL = Self.defaultSessionsRoot()) {
        self.sessionsRoot = sessionsRoot
    }

    public static func defaultSessionsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sessions", directoryHint: .isDirectory)
    }

    public func resolve(originToken: String) throws -> String {
        try resolveRecoveryOrigin(originToken: originToken).threadID
    }

    public func resolveRecoveryOrigin(originToken: String) throws -> RecoveryOrigin {
        guard UUID(uuidString: originToken) != nil else {
            throw ThreadOriginResolverError.invalidToken
        }
        let files = recentRollouts()
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let content = String(data: data, encoding: .utf8),
                  content.contains(originToken),
                  let threadID = threadID(from: content) else { continue }
            let snapshot = RecoveryContextExtractor().extract(
                from: content,
                originToken: originToken
            )
            return RecoveryOrigin(threadID: threadID, contextSnapshot: snapshot)
        }
        throw ThreadOriginResolverError.originNotFound
    }

    private func recentRollouts() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(100).map(\.0)
    }

    private func threadID(from content: String) -> String? {
        for line in content.split(separator: "\n", omittingEmptySubsequences: true).prefix(20) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else { continue }
            return payload["id"] as? String ?? payload["session_id"] as? String
        }
        return nil
    }
}

public struct RecoveryOrigin: Equatable, Sendable {
    public let threadID: String
    public let contextSnapshot: String

    public init(threadID: String, contextSnapshot: String) {
        self.threadID = threadID
        self.contextSnapshot = contextSnapshot
    }
}
