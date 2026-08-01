import Foundation
import Testing
@testable import GuardianCore

@Test func optionalPluginFailureDegradesButCannotBlockContinuation() {
    let decision = GuardianReadinessPolicy().decision(
        records: [
            readiness("desktop.started", requirement: .required, state: .ready),
            readiness("control.ready", requirement: .required, state: .ready),
            readiness("schema.ready", requirement: .required, state: .ready),
            readiness("target.loaded", requirement: .required, state: .ready),
            readiness("plugin.context-mode", requirement: .optional, state: .failed),
        ],
        now: Date(timeIntervalSince1970: 105)
    )

    #expect(decision == .ready(degraded: ["plugin.context-mode"]))
}

@Test func expiredOptionalPendingCapabilityBecomesNamedDegradation() {
    let decision = GuardianReadinessPolicy().decision(
        records: [
            readiness("desktop.started", requirement: .required, state: .ready),
            readiness(
                "plugin.context-mode",
                requirement: .optional,
                state: .pending,
                deadline: Date(timeIntervalSince1970: 104)
            ),
        ],
        now: Date(timeIntervalSince1970: 105)
    )

    #expect(decision == .ready(degraded: ["plugin.context-mode"]))
}

@Test func failedRequiredCapabilityBlocksWithExactName() {
    let decision = GuardianReadinessPolicy().decision(
        records: [
            readiness("desktop.started", requirement: .required, state: .ready),
            readiness("control.ready", requirement: .required, state: .failed),
            readiness("plugin.context-mode", requirement: .optional, state: .failed),
        ],
        now: Date(timeIntervalSince1970: 105)
    )

    #expect(decision == .blocked(required: ["control.ready"]))
}

@Test func unexpiredRequiredCapabilityWaitsWithExactName() {
    let decision = GuardianReadinessPolicy().decision(
        records: [
            readiness(
                "control.ready",
                requirement: .required,
                state: .pending,
                deadline: Date(timeIntervalSince1970: 110)
            ),
        ],
        now: Date(timeIntervalSince1970: 105)
    )

    #expect(decision == .waiting(required: ["control.ready"]))
}

@Test func emptyManifestNeverMeansReady() {
    #expect(GuardianReadinessPolicy().decision(
        records: [],
        now: Date(timeIntervalSince1970: 105)
    ) == .blocked(required: ["readiness.manifest"]))
}

private func readiness(
    _ capability: String,
    requirement: GuardianCapabilityRequirement,
    state: GuardianCapabilityState,
    deadline: Date = Date(timeIntervalSince1970: 110)
) -> GuardianCapabilityRecord {
    GuardianCapabilityRecord(
        capability: capability,
        requirement: requirement,
        state: state,
        evidenceID: "evidence-\(capability)",
        observedAt: Date(timeIntervalSince1970: 100),
        deadline: deadline
    )
}
