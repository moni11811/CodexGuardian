import CryptoKit
import Foundation

public struct CodexAppServerRecoveryLivenessPolicy: Equatable, Sendable {
    public let initialSilenceTimeout: TimeInterval
    public let startupProgressTimeout: TimeInterval
    public let hookProgressTimeout: TimeInterval
    public let turnProgressTimeout: TimeInterval
    public let hardTimeout: TimeInterval

    public init(
        initialSilenceTimeout: TimeInterval,
        startupProgressTimeout: TimeInterval,
        hookProgressTimeout: TimeInterval,
        turnProgressTimeout: TimeInterval,
        hardTimeout: TimeInterval
    ) {
        self.initialSilenceTimeout = Self.valid(initialSilenceTimeout)
        self.startupProgressTimeout = Self.valid(startupProgressTimeout)
        self.hookProgressTimeout = Self.valid(hookProgressTimeout)
        self.turnProgressTimeout = Self.valid(turnProgressTimeout)
        self.hardTimeout = Self.valid(hardTimeout)
    }

    public static let production = CodexAppServerRecoveryLivenessPolicy(
        initialSilenceTimeout: 60,
        startupProgressTimeout: 90,
        hookProgressTimeout: 180,
        turnProgressTimeout: 120,
        hardTimeout: 600
    )

    fileprivate func timeout(for method: String) -> TimeInterval? {
        if method == "mcpServer/startupStatus/updated" {
            return startupProgressTimeout
        }
        if method.hasPrefix("hook/") {
            return hookProgressTimeout
        }
        if method.hasPrefix("item/")
            || (method.hasPrefix("turn/") && method != "turn/completed") {
            return turnProgressTimeout
        }
        return nil
    }

    private static func valid(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0.001 }
        return value
    }
}

public struct CodexAppServerRecoveryLivenessTracker: Sendable {
    public let hardDeadline: Date
    public private(set) var deadline: Date

    private let policy: CodexAppServerRecoveryLivenessPolicy
    private var observedFingerprints: Set<Data> = []

    public init(
        policy: CodexAppServerRecoveryLivenessPolicy = .production,
        startedAt: Date = Date(),
        hardDeadline: Date? = nil
    ) {
        self.policy = policy
        let policyHardDeadline = startedAt.addingTimeInterval(policy.hardTimeout)
        self.hardDeadline = min(hardDeadline ?? policyHardDeadline, policyHardDeadline)
        self.deadline = min(
            startedAt.addingTimeInterval(policy.initialSilenceTimeout),
            self.hardDeadline
        )
    }

    @discardableResult
    public mutating func observe(
        notification: Data,
        expectedThreadID: String,
        at date: Date = Date()
    ) throws -> Bool {
        guard !expectedThreadID.isEmpty,
              let object = try JSONSerialization.jsonObject(with: notification)
                as? [String: Any],
              let method = object["method"] as? String else {
            throw CodexAppServerRecoveryProtocolError.invalidJSON
        }
        guard let timeout = policy.timeout(for: method),
              let params = object["params"] as? [String: Any],
              params["threadId"] as? String == expectedThreadID else {
            return false
        }
        let fingerprintObject: [String: Any] = [
            "method": method,
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(fingerprintObject) else {
            throw CodexAppServerRecoveryProtocolError.invalidJSON
        }
        let canonical = try JSONSerialization.data(
            withJSONObject: fingerprintObject,
            options: [.sortedKeys]
        )
        let fingerprint = Data(SHA256.hash(data: canonical))
        guard observedFingerprints.insert(fingerprint).inserted else { return false }

        deadline = min(
            max(deadline, date.addingTimeInterval(timeout)),
            hardDeadline
        )
        return true
    }
}
