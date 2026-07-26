import Foundation

public enum RestartRecoveryPhase: String, Codable, Equatable, Sendable {
    case queued
    case claimed
    case awaitingContinuation
    case deliveringContinuation
}

public enum RestartRequestStoreError: Error, Equatable, Sendable {
    case duplicateOriginToken
    case heartbeatNotObserved
}

extension RestartRequestStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateOriginToken:
            return "The recovery origin token already belongs to another restart request."
        case .heartbeatNotObserved:
            return "The native recovery heartbeat has not been observed."
        }
    }
}

public enum ContinuationLeaseResult: Equatable, Sendable {
    case waiting
    case delivery(RestartRequest)

    public var isDelivery: Bool {
        if case .delivery = self { return true }
        return false
    }

    public var request: RestartRequest? {
        if case let .delivery(request) = self { return request }
        return nil
    }
}

public struct RestartRequest: Codable, Equatable, Sendable {
    public static let defaultPrompt = "Continue this task. The previous tool call became stuck. Do not repeat the unchanged method; inspect current state and use a fallback."

    public let id: UUID
    public let requestedAt: Date
    public let threadID: String
    public let recoveryPrompt: String
    public let contextSnapshot: String?
    public let delaySeconds: Int
    public let targetBundleIdentifier: String
    public let originToken: String?
    public let continuationAutomationID: String?
    public let recoveryPhase: RestartRecoveryPhase
    public let heartbeatObservedAt: Date?
    public let restartProcessIdentifier: Int32?
    public let restartedAt: Date?
    public let deliveryLeaseStartedAt: Date?

    public init(
        id: UUID = UUID(),
        requestedAt: Date = Date(),
        threadID: String = "",
        recoveryPrompt: String = RestartRequest.defaultPrompt,
        contextSnapshot: String? = nil,
        delaySeconds: Int = 2,
        targetBundleIdentifier: String = "com.openai.codex",
        originToken: String? = nil,
        continuationAutomationID: String? = nil,
        recoveryPhase: RestartRecoveryPhase = .queued,
        heartbeatObservedAt: Date? = nil,
        restartProcessIdentifier: Int32? = nil,
        restartedAt: Date? = nil,
        deliveryLeaseStartedAt: Date? = nil
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.threadID = threadID
        self.recoveryPrompt = recoveryPrompt
        self.contextSnapshot = contextSnapshot
        self.delaySeconds = min(max(delaySeconds, 1), 30)
        self.targetBundleIdentifier = targetBundleIdentifier
        self.originToken = originToken
        self.continuationAutomationID = continuationAutomationID
        self.recoveryPhase = recoveryPhase
        self.heartbeatObservedAt = heartbeatObservedAt
        self.restartProcessIdentifier = restartProcessIdentifier
        self.restartedAt = restartedAt
        self.deliveryLeaseStartedAt = deliveryLeaseStartedAt
    }

    public var automaticContinuationIsArmed: Bool {
        !threadID.isEmpty
            && originToken.flatMap(UUID.init(uuidString:)) != nil
            && continuationAutomationID?.isEmpty == false
    }

    public func withRecoveryPrompt(_ prompt: String) -> RestartRequest {
        RestartRequest(
            id: id,
            requestedAt: requestedAt,
            threadID: threadID,
            recoveryPrompt: prompt,
            contextSnapshot: contextSnapshot,
            delaySeconds: delaySeconds,
            targetBundleIdentifier: targetBundleIdentifier,
            originToken: originToken,
            continuationAutomationID: continuationAutomationID,
            recoveryPhase: recoveryPhase,
            heartbeatObservedAt: heartbeatObservedAt,
            restartProcessIdentifier: restartProcessIdentifier,
            restartedAt: restartedAt,
            deliveryLeaseStartedAt: deliveryLeaseStartedAt
        )
    }

    public func withRecoveryPhase(_ phase: RestartRecoveryPhase) -> RestartRequest {
        RestartRequest(
            id: id,
            requestedAt: requestedAt,
            threadID: threadID,
            recoveryPrompt: recoveryPrompt,
            contextSnapshot: contextSnapshot,
            delaySeconds: delaySeconds,
            targetBundleIdentifier: targetBundleIdentifier,
            originToken: originToken,
            continuationAutomationID: continuationAutomationID,
            recoveryPhase: phase,
            heartbeatObservedAt: heartbeatObservedAt,
            restartProcessIdentifier: restartProcessIdentifier,
            restartedAt: restartedAt,
            deliveryLeaseStartedAt: deliveryLeaseStartedAt
        )
    }

    public func withHeartbeatObserved(at date: Date) -> RestartRequest {
        copy(heartbeatObservedAt: date)
    }

    public func awaitingContinuation(
        processIdentifier: Int32,
        restartedAt: Date
    ) -> RestartRequest {
        copy(
            recoveryPhase: .awaitingContinuation,
            restartProcessIdentifier: processIdentifier,
            restartedAt: restartedAt,
            deliveryLeaseStartedAt: nil
        )
    }

    public func withDeliveryLease(startedAt: Date) -> RestartRequest {
        copy(
            recoveryPhase: .deliveringContinuation,
            deliveryLeaseStartedAt: startedAt
        )
    }

    private func copy(
        recoveryPhase: RestartRecoveryPhase? = nil,
        heartbeatObservedAt: Date?? = nil,
        restartProcessIdentifier: Int32?? = nil,
        restartedAt: Date?? = nil,
        deliveryLeaseStartedAt: Date?? = nil
    ) -> RestartRequest {
        RestartRequest(
            id: id,
            requestedAt: requestedAt,
            threadID: threadID,
            recoveryPrompt: recoveryPrompt,
            contextSnapshot: contextSnapshot,
            delaySeconds: delaySeconds,
            targetBundleIdentifier: targetBundleIdentifier,
            originToken: originToken,
            continuationAutomationID: continuationAutomationID,
            recoveryPhase: recoveryPhase ?? self.recoveryPhase,
            heartbeatObservedAt: heartbeatObservedAt ?? self.heartbeatObservedAt,
            restartProcessIdentifier: restartProcessIdentifier ?? self.restartProcessIdentifier,
            restartedAt: restartedAt ?? self.restartedAt,
            deliveryLeaseStartedAt: deliveryLeaseStartedAt ?? self.deliveryLeaseStartedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, requestedAt, threadID, recoveryPrompt, contextSnapshot
        case delaySeconds, targetBundleIdentifier, originToken
        case continuationAutomationID, recoveryPhase
        case heartbeatObservedAt, restartProcessIdentifier, restartedAt, deliveryLeaseStartedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            requestedAt: try values.decode(Date.self, forKey: .requestedAt),
            threadID: try values.decodeIfPresent(String.self, forKey: .threadID) ?? "",
            recoveryPrompt: try values.decodeIfPresent(String.self, forKey: .recoveryPrompt)
                ?? Self.defaultPrompt,
            contextSnapshot: try values.decodeIfPresent(String.self, forKey: .contextSnapshot),
            delaySeconds: try values.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 2,
            targetBundleIdentifier: try values.decodeIfPresent(
                String.self,
                forKey: .targetBundleIdentifier
            ) ?? "com.openai.codex",
            originToken: try values.decodeIfPresent(String.self, forKey: .originToken),
            continuationAutomationID: try values.decodeIfPresent(
                String.self,
                forKey: .continuationAutomationID
            ),
            recoveryPhase: try values.decodeIfPresent(
                RestartRecoveryPhase.self,
                forKey: .recoveryPhase
            ) ?? .queued,
            heartbeatObservedAt: try values.decodeIfPresent(Date.self, forKey: .heartbeatObservedAt),
            restartProcessIdentifier: try values.decodeIfPresent(
                Int32.self,
                forKey: .restartProcessIdentifier
            ),
            restartedAt: try values.decodeIfPresent(Date.self, forKey: .restartedAt),
            deliveryLeaseStartedAt: try values.decodeIfPresent(
                Date.self,
                forKey: .deliveryLeaseStartedAt
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(requestedAt, forKey: .requestedAt)
        try values.encode(threadID, forKey: .threadID)
        try values.encode(recoveryPrompt, forKey: .recoveryPrompt)
        try values.encodeIfPresent(contextSnapshot, forKey: .contextSnapshot)
        try values.encode(delaySeconds, forKey: .delaySeconds)
        try values.encode(targetBundleIdentifier, forKey: .targetBundleIdentifier)
        try values.encodeIfPresent(originToken, forKey: .originToken)
        try values.encodeIfPresent(continuationAutomationID, forKey: .continuationAutomationID)
        try values.encode(recoveryPhase, forKey: .recoveryPhase)
        try values.encodeIfPresent(heartbeatObservedAt, forKey: .heartbeatObservedAt)
        try values.encodeIfPresent(restartProcessIdentifier, forKey: .restartProcessIdentifier)
        try values.encodeIfPresent(restartedAt, forKey: .restartedAt)
        try values.encodeIfPresent(deliveryLeaseStartedAt, forKey: .deliveryLeaseStartedAt)
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

    @discardableResult
    public func enqueueUnique(_ request: RestartRequest) throws -> UUID {
        if let token = request.originToken,
           let existing = try self.request(originToken: token) {
            guard existing.threadID == request.threadID,
                  existing.continuationAutomationID == request.continuationAutomationID else {
                throw RestartRequestStoreError.duplicateOriginToken
            }
            return existing.id
        }
        try enqueue(request)
        return request.id
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

    public func peekAllPending() throws -> [RestartRequest] {
        try pendingRequests().map(\.request)
    }

    public func claimPending(ids: Set<UUID>) throws {
        try FileManager.default.createDirectory(
            at: claimedDirectory,
            withIntermediateDirectories: true
        )
        let matching = try pendingRequests().filter { ids.contains($0.request.id) }
        guard Set(matching.map(\.request.id)) == ids else {
            throw CocoaError(.fileNoSuchFile)
        }
        for pending in matching {
            let destination = claimedDirectory.appending(path: pending.url.lastPathComponent)
            try FileManager.default.moveItem(at: pending.url, to: destination)
            let claimed = pending.request.withRecoveryPhase(.claimed)
            try JSONEncoder().encode(claimed).write(to: destination, options: .atomic)
        }
    }

    public func markClaimAwaitingContinuation(
        id: UUID,
        processIdentifier: Int32,
        restartedAt: Date
    ) throws {
        guard let item = try claimedItems().first(where: { $0.request.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard item.request.recoveryPhase == .claimed,
              item.request.heartbeatObservedAt != nil,
              processIdentifier > 0 else {
            throw RestartRequestStoreError.heartbeatNotObserved
        }
        let awaiting = item.request.awaitingContinuation(
            processIdentifier: processIdentifier,
            restartedAt: restartedAt
        )
        try JSONEncoder().encode(awaiting).write(to: item.url, options: .atomic)
    }

    public func updateClaimedRequests(_ requests: [RestartRequest]) throws {
        let updates = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        guard updates.count == requests.count else { throw CocoaError(.fileWriteInvalidFileName) }
        let matching = try claimedItems().filter { updates[$0.request.id] != nil }
        guard Set(matching.map(\.request.id)) == Set(updates.keys) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for item in matching {
            guard let update = updates[item.request.id],
                  update.threadID == item.request.threadID,
                  update.originToken == item.request.originToken,
                  update.continuationAutomationID == item.request.continuationAutomationID else {
                throw CocoaError(.fileWriteUnknown)
            }
            let persisted = update.withRecoveryPhase(item.request.recoveryPhase)
            try JSONEncoder().encode(persisted).write(to: item.url, options: .atomic)
        }
    }

    public func request(originToken: String) throws -> RestartRequest? {
        let pending = try pendingRequests().map(\.request)
        let claimed = try claimedItems().map(\.request)
        let matches = (pending + claimed).filter { $0.originToken == originToken }
        guard matches.count <= 1 else { throw RestartRequestStoreError.duplicateOriginToken }
        return matches.first
    }

    @discardableResult
    public func markHeartbeatObserved(originToken: String, at date: Date = Date()) throws -> UUID? {
        let matching = try locatedItems(originToken: originToken)
        guard matching.count <= 1 else { throw RestartRequestStoreError.duplicateOriginToken }
        guard let item = matching.first else { return nil }
        let observed = item.request.withHeartbeatObserved(at: date)
        try JSONEncoder().encode(observed).write(to: item.url, options: .atomic)
        return observed.id
    }

    public func leaseContinuation(
        originToken: String,
        now: Date = Date(),
        leaseDuration: TimeInterval = 300
    ) throws -> ContinuationLeaseResult {
        let matching = try claimedItems().filter { $0.request.originToken == originToken }
        guard matching.count <= 1 else { throw RestartRequestStoreError.duplicateOriginToken }
        guard let item = matching.first else { return .waiting }
        switch item.request.recoveryPhase {
        case .awaitingContinuation:
            break
        case .deliveringContinuation:
            guard let startedAt = item.request.deliveryLeaseStartedAt,
                  now.timeIntervalSince(startedAt) >= leaseDuration else { return .waiting }
        case .queued, .claimed:
            return .waiting
        }
        let leased = item.request.withDeliveryLease(startedAt: now)
        try JSONEncoder().encode(leased).write(to: item.url, options: .atomic)
        return .delivery(leased)
    }

    @discardableResult
    public func acknowledgeContinuation(originToken: String) throws -> UUID? {
        guard let item = try claimedItems().first(where: {
            $0.request.originToken == originToken
                && $0.request.recoveryPhase == .deliveringContinuation
        }) else { return nil }
        try FileManager.default.removeItem(at: item.url)
        return item.request.id
    }

    public func recoverClaims() throws {
        guard FileManager.default.fileExists(atPath: claimedDirectory.path) else { return }
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        for item in try claimedItems() {
            guard ![.awaitingContinuation, .deliveringContinuation]
                .contains(item.request.recoveryPhase) else { continue }
            var destination = queueDirectory.appending(path: item.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = queueDirectory.appending(path: "recovered-\(UUID().uuidString).json")
            }
            let queued = item.request.withRecoveryPhase(.queued)
            try JSONEncoder().encode(queued).write(to: destination, options: .atomic)
            try FileManager.default.removeItem(at: item.url)
        }
    }

    public func completeClaims(ids: Set<UUID>) throws {
        for url in try claimURLs() {
            let request = try JSONDecoder().decode(
                RestartRequest.self,
                from: Data(contentsOf: url)
            )
            if ids.contains(request.id) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public var pendingURL: URL {
        directory.appending(path: "pending-restart.json")
    }

    public var queueDirectory: URL {
        directory.appending(path: "pending", directoryHint: .isDirectory)
    }

    public var claimedDirectory: URL {
        directory.appending(path: "claimed", directoryHint: .isDirectory)
    }

    private func requestURL(for request: RestartRequest) -> URL {
        let timestamp = String(format: "%020.6f", request.requestedAt.timeIntervalSince1970)
        return queueDirectory.appending(path: "\(timestamp)-\(request.id.uuidString).json")
    }

    private func claimURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: claimedDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: claimedDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func claimedItems() throws -> [(url: URL, request: RestartRequest)] {
        try claimURLs().map { url in
            let request = try JSONDecoder().decode(
                RestartRequest.self,
                from: Data(contentsOf: url)
            )
            return (url, request)
        }
    }

    private func locatedItems(originToken: String) throws -> [(url: URL, request: RestartRequest)] {
        let pending = try pendingRequests().filter { $0.request.originToken == originToken }
        let claimed = try claimedItems().filter { $0.request.originToken == originToken }
        return pending + claimed
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
