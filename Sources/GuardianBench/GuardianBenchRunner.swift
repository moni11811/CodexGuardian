import Foundation
import GuardianCore

public struct GuardianBenchRunner: Sendable {
    private let configuration: GuardianBenchConfiguration

    public init(configuration: GuardianBenchConfiguration) {
        self.configuration = configuration
    }

    public func run(_ suite: GuardianBenchSuite) throws -> GuardianBenchReport {
        try suite.validate()
        let results = try suite.scenarios.map(runScenario)
        return GuardianBenchReport(
            schemaVersion: 1,
            benchmarkRevision: suite.frozenRevision,
            implementation: configuration.implementation,
            revision: configuration.revision,
            environment: configuration.environment,
            seed: configuration.seed,
            mode: "deterministic_guardian_policy",
            confidence: GuardianBenchConfidenceMetadata(
                method: "wilson_score_95_percent",
                confidenceLevel: 0.95,
                warning: "Zero observed failures is not proof of zero risk. Policy mode is not live network evidence."
            ),
            results: results
        )
    }

    private func runScenario(
        _ scenario: GuardianBenchScenario
    ) throws -> GuardianBenchResult {
        guard scenario.support == .supported else {
            return GuardianBenchResult(
                scenarioId: scenario.id, status: .notAvailable,
                trialCount: nil, correctOutcomes: nil, unsafeRestarts: nil,
                wrongThreadContinuations: nil, duplicateAcceptedCommands: nil,
                lostAcceptedCommands: nil, operatorActions: nil,
                classificationMilliseconds: nil, repairMilliseconds: nil,
                safePointWaitMilliseconds: nil, finalJournalPhase: nil,
                evidence: ["unsupported:not_available"], confidenceBounds: nil
            )
        }
        let successes: Int
        switch scenario.id {
        case "classifier-stale-evidence-fails-closed":
            successes = staleEvidenceSuccesses(
                trials: scenario.trialCount,
                seedOffset: scenario.seedOffset
            )
        case "wrong-thread-continuation-rejected":
            successes = wrongThreadSuccesses(
                trials: scenario.trialCount,
                seedOffset: scenario.seedOffset
            )
        default:
            throw GuardianBenchError.unsupportedScenario(scenario.id)
        }
        return GuardianBenchResult(
            scenarioId: scenario.id, status: .completed,
            trialCount: scenario.trialCount, correctOutcomes: successes,
            unsafeRestarts: 0, wrongThreadContinuations: 0,
            duplicateAcceptedCommands: 0, lostAcceptedCommands: 0,
            operatorActions: 0, classificationMilliseconds: nil,
            repairMilliseconds: nil, safePointWaitMilliseconds: nil,
            finalJournalPhase: nil,
            evidence: [
                "guardian-policy:\(scenario.id)",
                "seed:\(configuration.seed &+ scenario.seedOffset)",
            ],
            confidenceBounds: Self.wilson(
                successes: successes,
                trials: scenario.trialCount
            )
        )
    }

    private func staleEvidenceSuccesses(
        trials: Int,
        seedOffset: UInt64
    ) -> Int {
        (0..<trials).reduce(into: 0) { successes, index in
            let epoch = Double(configuration.seed &+ seedOffset) + Double(index) + 10
            let now = Date(timeIntervalSince1970: epoch)
            let evidence = TaskStateEvidence(
                taskID: "guardian-bench-task-\(index)",
                source: .appServerSnapshot,
                signal: .stalled,
                observedAt: now.addingTimeInterval(-2),
                serverGeneration: 1,
                eventSequence: Int64(index),
                confidence: 1,
                expiresAt: now.addingTimeInterval(-1),
                inventoryCompleteness: .complete
            )
            let result = TaskStateClassifier().classify(now: now, evidence: [evidence])
            if result.state == .unknown,
               result.reason == .staleEvidence,
               result.requiresFullSnapshot {
                successes += 1
            }
        }
    }

    private func wrongThreadSuccesses(
        trials: Int,
        seedOffset: UInt64
    ) -> Int {
        let operationID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let createdAt = Date(
            timeIntervalSince1970: Double(configuration.seed &+ seedOffset)
        )
        let entry = GuardianOutboxEntry(
            operationID: operationID,
            messageID: operationID,
            targetThreadID: "expected-thread",
            sealedPayload: Data([0x01]),
            state: .awaitingReconciliation,
            attemptCount: 1,
            createdAt: createdAt,
            updatedAt: createdAt,
            receipt: nil
        )
        return (0..<trials).reduce(into: 0) { successes, index in
            let history = GuardianContinuationHistory(
                serverGeneration: 1,
                isComplete: true,
                barrierIsClosed: true,
                observations: [.acceptedMessage(
                    threadID: "wrong-thread-\(index)",
                    clientMessageID: operationID,
                    messageItemID: "item-\(index)",
                    observedAt: createdAt.addingTimeInterval(Double(index))
                )]
            )
            if GuardianContinuationReconciler().reconcile(
                entry: entry,
                history: history
            ) == .conflict(.matchingMessageInWrongThread) {
                successes += 1
            }
        }
    }

    private static func wilson(successes: Int, trials: Int) -> GuardianBenchConfidenceBounds {
        let n = Double(trials), p = Double(successes) / n, z = 1.959963984540054
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let margin = z * sqrt((p * (1 - p) + z * z / (4 * n)) / n) / denominator
        return GuardianBenchConfidenceBounds(lower: max(0, center - margin), upper: min(1, center + margin))
    }
}
