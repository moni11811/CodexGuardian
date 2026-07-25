import Foundation

public struct RestartRequest: Codable, Equatable, Sendable {
    public static let defaultPrompt = "Continue this task. The previous tool call became stuck. Do not repeat the unchanged method; inspect current state and use a fallback."

    public let id: UUID
    public let requestedAt: Date
    public let threadID: String
    public let recoveryPrompt: String
    public let delaySeconds: Int
    public let targetBundleIdentifier: String

    public init(
        id: UUID = UUID(),
        requestedAt: Date = Date(),
        threadID: String = "",
        recoveryPrompt: String = RestartRequest.defaultPrompt,
        delaySeconds: Int = 2,
        targetBundleIdentifier: String = "com.openai.codex"
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.threadID = threadID
        self.recoveryPrompt = recoveryPrompt
        self.delaySeconds = min(max(delaySeconds, 1), 30)
        self.targetBundleIdentifier = targetBundleIdentifier
    }
}

public struct RestartRequestStore: Sendable {
    public let directory: URL

    public init(directory: URL = Self.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_GUARDIAN_STATE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CodexGuardian", directoryHint: .isDirectory)
    }

    public func enqueue(_ request: RestartRequest) throws {
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(request)
        try data.write(to: requestURL(for: request), options: .atomic)
    }

    public func takePending() throws -> RestartRequest? {
        guard let first = try pendingRequests().first else { return nil }
        try FileManager.default.removeItem(at: first.url)
        return first.request
    }

    public func takeAllPending() throws -> [RestartRequest] {
        let pending = try pendingRequests()
        for item in pending {
            try FileManager.default.removeItem(at: item.url)
        }
        return pending.map(\.request)
    }

    public var pendingURL: URL {
        directory.appending(path: "pending-restart.json")
    }

    public var queueDirectory: URL {
        directory.appending(path: "pending", directoryHint: .isDirectory)
    }

    private func requestURL(for request: RestartRequest) -> URL {
        let timestamp = String(format: "%020.6f", request.requestedAt.timeIntervalSince1970)
        return queueDirectory.appending(path: "\(timestamp)-\(request.id.uuidString).json")
    }

    private func pendingRequests() throws -> [(url: URL, request: RestartRequest)] {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: queueDirectory.path) {
            urls += try FileManager.default.contentsOfDirectory(
                at: queueDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        }
        if FileManager.default.fileExists(atPath: pendingURL.path) {
            urls.append(pendingURL)
        }
        return try urls.map { url in
            let request = try JSONDecoder().decode(RestartRequest.self, from: Data(contentsOf: url))
            return (url, request)
        }.sorted {
            if $0.request.requestedAt == $1.request.requestedAt {
                return $0.request.id.uuidString < $1.request.id.uuidString
            }
            return $0.request.requestedAt < $1.request.requestedAt
        }
    }
}
