import Foundation
import GuardianBench
import Testing

@Test func guardianBenchFrozenScenariosValidateAndUnsupportedIsNotAvailable() throws {
    let fixtureURL = GuardianBenchPaths.repositoryRoot
        .appending(path: "Benchmarks/GuardianBench/scenarios.v1.json")
    let suite = try GuardianBenchCodec.decodeSuite(Data(contentsOf: fixtureURL))

    try suite.validate()
    #expect(!suite.scenarios.isEmpty)
    #expect(suite.scenarios.contains { $0.support == .notAvailable })
}

@Test func guardianBenchSeededRunnerIsDeterministicAndPublishesConfidenceMetadata() throws {
    let suite = GuardianBenchSuite(
        schemaVersion: 1,
        frozenRevision: "test-fixture-v1",
        scenarios: [
            GuardianBenchScenario(
                id: "classifier-stale-evidence-fails-closed",
                severity: .critical,
                support: .supported,
                trialCount: 10,
                seedOffset: 7
            ),
            GuardianBenchScenario(
                id: "unsupported",
                severity: .high,
                support: .notAvailable,
                trialCount: 10,
                seedOffset: 8
            ),
        ]
    )
    let configuration = GuardianBenchConfiguration(
        implementation: "fixture",
        revision: "abc123",
        seed: 42,
        environment: "deterministic-local"
    )

    let first = try GuardianBenchRunner(configuration: configuration).run(suite)
    let second = try GuardianBenchRunner(configuration: configuration).run(suite)

    #expect(try GuardianBenchCodec.encode(first) == GuardianBenchCodec.encode(second))
    #expect(first.confidence.method == "wilson_score_95_percent")
    #expect(first.results.first?.confidenceBounds != nil)
    #expect(first.mode == "deterministic_guardian_policy")
    #expect(first.results.first?.classificationMilliseconds == nil)
    #expect(first.results.first?.repairMilliseconds == nil)
    #expect(first.results.first?.safePointWaitMilliseconds == nil)
    #expect(first.results.first?.evidence.allSatisfy { !$0.contains("fixture") } == true)
    #expect(first.results.last?.status == .notAvailable)
    #expect(first.results.last?.confidenceBounds == nil)
}

@Test func guardianBenchRejectsUnknownSupportedScenarioInsteadOfFabricatingProof() throws {
    let suite = GuardianBenchSuite(
        schemaVersion: 1,
        frozenRevision: "test-fixture-v1",
        scenarios: [.init(
            id: "unknown-supported-scenario",
            severity: .critical,
            support: .supported,
            trialCount: 10,
            seedOffset: 1
        )]
    )

    #expect(throws: GuardianBenchError.unsupportedScenario(
        "unknown-supported-scenario"
    )) {
        try GuardianBenchRunner(configuration: .init(
            implementation: "fixture",
            revision: "abc123",
            seed: 42,
            environment: "deterministic-local"
        )).run(suite)
    }
}

@Test func guardianBenchPublishesMachineReadableReportSchema() throws {
    let schemaURL = GuardianBenchPaths.repositoryRoot
        .appending(path: "Benchmarks/GuardianBench/result-schema.v1.json")
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL))
            as? [String: Any]
    )
    #expect(object["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
    let required = try #require(object["required"] as? [String])
    #expect(Set(required).isSuperset(of: [
        "schemaVersion", "benchmarkRevision", "implementation", "revision",
        "environment", "seed", "mode", "confidence", "results",
    ]))
}
