import Foundation

public enum GuardianDiagnosticKind: String, Codable, Equatable, Sendable {
    case inspectToolHost
    case inspectMCPRegistration
    case probeControlPlane
    case requestFreshSnapshot
    case inspectDesktopReadiness
    case checkPermissions
    case checkDiskCapacity
    case checkNetwork
}

public enum GuardianAdviceSource: String, Codable, Equatable, Sendable {
    case deterministic
    case localModel
}

public struct GuardianAdvisorContext: Codable, Equatable, Sendable {
    public let failureFamily: RepairFailureFamily
    public let taskState: AuthoritativeTaskState
    public let blockers: [String]
    public let verifiedEvents: [String]
    public let repairHistory: [String]
    public let diffSummary: String?
    public let continuationFallback: String?
    public let evidenceIsComplete: Bool

    public init(
        failureFamily: RepairFailureFamily,
        taskState: AuthoritativeTaskState,
        blockers: [String],
        verifiedEvents: [String],
        repairHistory: [String],
        diffSummary: String?,
        continuationFallback: String?,
        evidenceIsComplete: Bool
    ) {
        self.failureFamily = failureFamily
        self.taskState = taskState
        self.blockers = blockers
        self.verifiedEvents = verifiedEvents
        self.repairHistory = repairHistory
        self.diffSummary = diffSummary
        self.continuationFallback = continuationFallback
        self.evidenceIsComplete = evidenceIsComplete
    }
}

public struct GuardianAdviceCandidate: Codable, Equatable, Sendable {
    public let summary: String
    public let likelyFailureFamily: RepairFailureFamily
    public let suggestedDiagnostic: GuardianDiagnosticKind?
    public let continuationDraft: String?
    public let uncertainty: String

    public init(
        summary: String,
        likelyFailureFamily: RepairFailureFamily,
        suggestedDiagnostic: GuardianDiagnosticKind?,
        continuationDraft: String?,
        uncertainty: String
    ) {
        self.summary = summary
        self.likelyFailureFamily = likelyFailureFamily
        self.suggestedDiagnostic = suggestedDiagnostic
        self.continuationDraft = continuationDraft
        self.uncertainty = uncertainty
    }
}

public struct GuardianAdvice: Codable, Equatable, Sendable {
    public let summary: String
    public let likelyFailureFamily: RepairFailureFamily
    public let suggestedDiagnostic: GuardianDiagnosticKind?
    public let continuationDraft: String?
    public let uncertainty: String
    public let source: GuardianAdviceSource

    public init(
        summary: String,
        likelyFailureFamily: RepairFailureFamily,
        suggestedDiagnostic: GuardianDiagnosticKind?,
        continuationDraft: String?,
        uncertainty: String,
        source: GuardianAdviceSource
    ) {
        self.summary = summary
        self.likelyFailureFamily = likelyFailureFamily
        self.suggestedDiagnostic = suggestedDiagnostic
        self.continuationDraft = continuationDraft
        self.uncertainty = uncertainty
        self.source = source
    }

    public var hasAuthority: Bool { false }
}

public struct GuardianAdvisor: Sendable {
    public typealias Model = @Sendable (
        GuardianAdvisorContext
    ) async throws -> GuardianAdviceCandidate

    public static let maximumInputCharacters = 6_000
    public static let maximumOutputCharacters = 1_200

    private let model: Model?

    public init(model: Model?) {
        self.model = model
    }

    public func advise(for context: GuardianAdvisorContext) async -> GuardianAdvice {
        let bounded = boundedContext(context)
        let fallback = deterministicAdvice(for: bounded)
        guard bounded.evidenceIsComplete,
              bounded.taskState != .unknown,
              !bounded.verifiedEvents.isEmpty,
              let model else {
            return fallback
        }
        do {
            let candidate = try await model(bounded)
            return validated(candidate, for: bounded) ?? fallback
        } catch {
            return fallback
        }
    }

    private func validated(
        _ candidate: GuardianAdviceCandidate,
        for context: GuardianAdvisorContext
    ) -> GuardianAdvice? {
        guard candidate.likelyFailureFamily == context.failureFamily,
              candidate.suggestedDiagnostic.map({
                  allowedDiagnostics(for: context.failureFamily).contains($0)
              }) ?? true else {
            return nil
        }
        let summary = sanitize(candidate.summary)
        let uncertainty = sanitize(candidate.uncertainty)
        guard outputTextIsAllowed(summary),
              outputTextIsAllowed(uncertainty) else {
            return nil
        }
        let continuation: String?
        if let draft = candidate.continuationDraft {
            let sanitizedDraft = sanitize(draft)
            let safeFallback = deterministicContinuation(for: context)
            let selected = RecoveryPromptPolicy().select(
                generated: sanitizedDraft,
                fallback: safeFallback
            )
            guard selected == sanitizedDraft else { return nil }
            continuation = selected
        } else {
            continuation = nil
        }
        return GuardianAdvice(
            summary: summary,
            likelyFailureFamily: context.failureFamily,
            suggestedDiagnostic: candidate.suggestedDiagnostic,
            continuationDraft: continuation,
            uncertainty: uncertainty,
            source: .localModel
        )
    }

    private func deterministicAdvice(
        for context: GuardianAdvisorContext
    ) -> GuardianAdvice {
        guard context.evidenceIsComplete,
              context.taskState != .unknown,
              !context.verifiedEvents.isEmpty else {
            return GuardianAdvice(
                summary: "Verified evidence is insufficient; Guardian will not infer safety.",
                likelyFailureFamily: context.failureFamily,
                suggestedDiagnostic: nil,
                continuationDraft: nil,
                uncertainty: "insufficient verified evidence",
                source: .deterministic
            )
        }
        let blocker = context.blockers.first ?? "No named blocker was supplied."
        return GuardianAdvice(
            summary: sanitize("\(context.failureFamily.rawValue): \(blocker)"),
            likelyFailureFamily: context.failureFamily,
            suggestedDiagnostic: defaultDiagnostic(for: context.failureFamily),
            continuationDraft: deterministicContinuation(for: context),
            uncertainty: "Advice is limited to supplied verified evidence.",
            source: .deterministic
        )
    }

    private func deterministicContinuation(
        for context: GuardianAdvisorContext
    ) -> String {
        let safeDefault = "Continue with the named non-destructive diagnostic, then record new evidence."
        guard let fallback = context.continuationFallback else { return safeDefault }
        return RecoveryPromptPolicy().select(
            generated: sanitize(fallback),
            fallback: safeDefault
        )
    }

    private func defaultDiagnostic(
        for family: RepairFailureFamily
    ) -> GuardianDiagnosticKind {
        switch family {
        case .tool: .inspectToolHost
        case .mcpHost: .inspectMCPRegistration
        case .controlPlane: .probeControlPlane
        case .thread: .requestFreshSnapshot
        case .desktop: .inspectDesktopReadiness
        case .permission: .checkPermissions
        case .disk: .checkDiskCapacity
        case .network, .externalDependency: .checkNetwork
        }
    }

    private func allowedDiagnostics(
        for family: RepairFailureFamily
    ) -> Set<GuardianDiagnosticKind> {
        [defaultDiagnostic(for: family)]
    }

    private func boundedContext(
        _ context: GuardianAdvisorContext
    ) -> GuardianAdvisorContext {
        var remaining = Self.maximumInputCharacters
        func bounded(_ values: [String], limit: Int) -> [String] {
            var result: [String] = []
            for value in values.prefix(limit) where remaining > 0 {
                let sanitized = sanitize(value)
                let prefix = String(sanitized.prefix(min(remaining, 500)))
                guard !prefix.isEmpty else { continue }
                result.append(prefix)
                remaining -= prefix.count
            }
            return result
        }
        let blockers = bounded(context.blockers, limit: 16)
        let events = bounded(context.verifiedEvents, limit: 32)
        let repairs = bounded(context.repairHistory, limit: 16)
        let diff = context.diffSummary.flatMap { value -> String? in
            guard remaining > 0 else { return nil }
            let output = String(sanitize(value).prefix(min(remaining, 1_000)))
            remaining -= output.count
            return output.isEmpty ? nil : output
        }
        let continuation = context.continuationFallback.map {
            String(sanitize($0).prefix(500))
        }
        return GuardianAdvisorContext(
            failureFamily: context.failureFamily,
            taskState: context.taskState,
            blockers: blockers,
            verifiedEvents: events,
            repairHistory: repairs,
            diffSummary: diff,
            continuationFallback: continuation,
            evidenceIsComplete: context.evidenceIsComplete
        )
    }

    private func sanitize(_ value: String) -> String {
        String(
            RecoveryContextExtractor()
                .sanitize(value, originToken: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumOutputCharacters)
        )
    }

    private func outputTextIsAllowed(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= Self.maximumOutputCharacters,
              !value.contains("{"),
              !value.contains("}") else {
            return false
        }
        let forbidden = [
            "restart_codex",
            "prepare_restart",
            "prepare_recovery",
            "recovery_tick",
            "ack_recovery",
            "origin_token",
            "tool_call",
            "function_call",
            "codex exec resume",
        ]
        return !forbidden.contains {
            value.localizedCaseInsensitiveContains($0)
        }
    }
}
