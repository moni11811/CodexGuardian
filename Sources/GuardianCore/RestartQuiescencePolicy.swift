import Foundation

public enum CodexTaskActivityState: Equatable, Sendable {
    case active
    case idle
}

public struct CodexTaskActivity: Equatable, Sendable {
    public let threadID: String
    public let modifiedAt: Date
    public let state: CodexTaskActivityState

    public init(threadID: String, modifiedAt: Date, state: CodexTaskActivityState) {
        self.threadID = threadID
        self.modifiedAt = modifiedAt
        self.state = state
    }
}

public struct CodexTaskActivityScan: Equatable, Sendable {
    public let activities: [CodexTaskActivity]
    public let isComplete: Bool

    public init(activities: [CodexTaskActivity], isComplete: Bool) {
        self.activities = activities
        self.isComplete = isComplete
    }
}

public enum RestartQuiescenceDecision: Equatable, Sendable {
    case waitForTasks([String])
    case waitForQuietPeriod
    case restart
}

public struct RestartQuiescencePolicy: Sendable {
    public let quietPeriod: TimeInterval
    public let activityLookback: TimeInterval

    public init(
        quietPeriod: TimeInterval = 15,
        activityLookback: TimeInterval = 12 * 60 * 60
    ) {
        self.quietPeriod = quietPeriod
        self.activityLookback = activityLookback
    }

    public func decision(
        requests: [RestartRequest],
        activities: [CodexTaskActivity],
        now: Date = Date()
    ) -> RestartQuiescenceDecision {
        guard let earliestRequest = requests.map(\.requestedAt).min() else {
            return .restart
        }
        let relevant = activities
        let knownThreadIDs = Set(relevant.map(\.threadID))
        let missingOriginIDs = Set(requests.map(\.threadID).filter { !knownThreadIDs.contains($0) })
        let activeIDs = Set(
            relevant.filter { $0.state == .active }.map(\.threadID)
        ).union(missingOriginIDs).sorted()
        if !activeIDs.isEmpty {
            return .waitForTasks(activeIDs)
        }

        let newestActivity = (relevant.map(\.modifiedAt) + requests.map(\.requestedAt)).max()
            ?? earliestRequest
        let requestedReadyAt = requests.map {
            $0.requestedAt.addingTimeInterval(TimeInterval($0.delaySeconds))
        }.max() ?? earliestRequest
        let quietReadyAt = newestActivity.addingTimeInterval(quietPeriod)
        if now < max(requestedReadyAt, quietReadyAt) {
            return .waitForQuietPeriod
        }
        return .restart
    }
}

public struct CodexTaskActivityScanner: Sendable {
    public let sessionsRoot: URL
    public let maximumFiles: Int

    public init(
        sessionsRoot: URL = ThreadOriginResolver.defaultSessionsRoot(),
        maximumFiles: Int = 200
    ) {
        self.sessionsRoot = sessionsRoot
        self.maximumFiles = maximumFiles
    }

    public func scan(modifiedSince: Date = .distantPast) throws -> CodexTaskActivityScan {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return CodexTaskActivityScan(activities: [], isComplete: false) }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modifiedAt = values.contentModificationDate,
                  modifiedAt >= modifiedSince else { continue }
            files.append((url, modifiedAt))
        }

        let selected = files.sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maximumFiles)
        let activities = try selected
            .compactMap { try activity(at: $0.url, modifiedAt: $0.modifiedAt) }
        return CodexTaskActivityScan(
            activities: activities,
            isComplete: files.count <= maximumFiles && activities.count == selected.count
        )
    }

    private func activity(at url: URL, modifiedAt: Date) throws -> CodexTaskActivity? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        try handle.seek(toOffset: 0)
        let prefix = try handle.read(upToCount: min(Int(size), 64 * 1_024)) ?? Data()
        guard let threadID = threadID(from: prefix) else { return nil }

        let tailSize = min(Int(size), 128 * 1_024)
        try handle.seek(toOffset: size - UInt64(tailSize))
        let tail = try handle.read(upToCount: tailSize) ?? Data()
        return CodexTaskActivity(
            threadID: threadID,
            modifiedAt: modifiedAt,
            state: state(from: tail)
        )
    }

    private func threadID(from data: Data) -> String? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(20) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else { continue }
            return payload["id"] as? String ?? payload["session_id"] as? String
        }
        return nil
    }

    private func state(from data: Data) -> CodexTaskActivityState {
        guard let line = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last,
              let lineData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return .active }
        let payload = object["payload"] as? [String: Any]
        let payloadType = payload?["type"] as? String
        if object["type"] as? String == "event_msg",
           payloadType == "task_complete" || payloadType == "turn_aborted" {
            return .idle
        }
        return .active
    }
}
