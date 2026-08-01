import Foundation
import Testing
@testable import GuardianCore

private let repairStart = Date(timeIntervalSince1970: 10_000)

private func incident(
    family: RepairFailureFamily = .tool,
    nature: RepairFailureNature = .deterministic,
    criticality: RepairCapabilityCriticality = .required,
    deadline: Date = repairStart.addingTimeInterval(60)
) -> RepairIncident {
    RepairIncident(
        family: family,
        nature: nature,
        criticality: criticality,
        symptom: "bounded fixture failure",
        missingProof: "successful component response",
        startedAt: repairStart,
        deadline: deadline
    )
}

private func attempt(
    _ action: RepairAction,
    changedVariable: String?,
    result: RepairAttemptResult,
    at date: Date = repairStart
) -> RepairAttempt {
    RepairAttempt(
        action: action,
        changedVariable: changedVariable,
        result: result,
        occurredAt: date
    )
}

@Test func unchangedDeterministicRetryIsForbidden() {
    let policy = RepairPolicy(configuration: .test)

    let decision = policy.authorize(
        proposal: RepairProposal(action: .retryOnce, changedVariable: nil),
        incident: incident(),
        previousAttempts: [],
        now: repairStart
    )

    #expect(decision == .denied(.unchangedDeterministicRetry))
}

@Test func transientFailureGetsOnlyOneBoundedRetry() {
    let policy = RepairPolicy(configuration: .test)
    let transient = incident(nature: .transient)

    let first = policy.nextDecision(
        for: transient,
        attempts: [],
        restartState: .empty,
        now: repairStart
    )
    let afterFailedRetry = policy.nextDecision(
        for: transient,
        attempts: [attempt(
            .retryOnce,
            changedVariable: "new connection and jitter",
            result: .failed
        )],
        restartState: .empty,
        now: repairStart.addingTimeInterval(6)
    )

    #expect(first == .perform(.retryOnce, attemptDeadline: repairStart.addingTimeInterval(5)))
    #expect(afterFailedRetry == .perform(
        .reloadToolHost,
        attemptDeadline: repairStart.addingTimeInterval(11)
    ))
}

@Test func successfulMCPReloadEndsRepairBeforeDesktopRestart() {
    let policy = RepairPolicy(configuration: .test)
    let mcpFailure = incident(family: .mcpHost)
    let attempts = [attempt(
        .reloadMCPHost,
        changedVariable: "reload failing server only",
        result: .succeeded
    )]

    let decision = policy.nextDecision(
        for: mcpFailure,
        attempts: attempts,
        restartState: .empty,
        now: repairStart.addingTimeInterval(1)
    )

    #expect(decision == .resolved(by: .reloadMCPHost))
}

@Test func restartBudgetCircuitAndManualResetSurviveSerialization() throws {
    let configuration = RepairPolicyConfiguration.test
    var state = RestartCircuitState.empty
    state = state.recordingDesktopRestart(
        at: repairStart,
        result: .failed,
        configuration: configuration
    )
    state = state.recordingDesktopRestart(
        at: repairStart.addingTimeInterval(11),
        result: .failed,
        configuration: configuration
    )

    let encoded = try JSONEncoder().encode(state)
    let restored = try JSONDecoder().decode(RestartCircuitState.self, from: encoded)
    let policy = RepairPolicy(configuration: configuration)

    #expect(restored.isOpen)
    #expect(policy.desktopRestartAuthorization(
        state: restored,
        now: repairStart.addingTimeInterval(30),
        operationDeadline: repairStart.addingTimeInterval(90)
    ) == .denied(.circuitOpen))

    let reset = restored.manuallyReset(at: repairStart.addingTimeInterval(31))
    #expect(!reset.isOpen)
    #expect(policy.desktopRestartAuthorization(
        state: reset,
        now: repairStart.addingTimeInterval(32),
        operationDeadline: repairStart.addingTimeInterval(90)
    ) == .denied(.restartBudgetExhausted))

    let nextHour = repairStart.addingTimeInterval(3_601)
    #expect(policy.desktopRestartAuthorization(
        state: reset,
        now: nextHour,
        operationDeadline: nextHour.addingTimeInterval(30)
    ) == .allowed(attemptDeadline: nextHour.addingTimeInterval(5)))
}

@Test func restartCooldownAndOperationDeadlineAreBounded() {
    let configuration = RepairPolicyConfiguration.test
    let state = RestartCircuitState.empty.recordingDesktopRestart(
        at: repairStart,
        result: .succeeded,
        configuration: configuration
    )
    let policy = RepairPolicy(configuration: configuration)

    #expect(policy.desktopRestartAuthorization(
        state: state,
        now: repairStart.addingTimeInterval(2),
        operationDeadline: repairStart.addingTimeInterval(40)
    ) == .denied(.cooldown(until: repairStart.addingTimeInterval(10))))
    #expect(policy.desktopRestartAuthorization(
        state: state,
        now: repairStart.addingTimeInterval(10),
        operationDeadline: repairStart.addingTimeInterval(12)
    ) == .allowed(attemptDeadline: repairStart.addingTimeInterval(12)))
    #expect(policy.desktopRestartAuthorization(
        state: state,
        now: repairStart.addingTimeInterval(40),
        operationDeadline: repairStart.addingTimeInterval(40)
    ) == .denied(.deadlineExceeded))
}

@Test func optionalMCPFailureBecomesNamedTerminalDegradation() {
    let policy = RepairPolicy(configuration: .test)
    let optional = incident(
        family: .mcpHost,
        criticality: .optional(capability: "context-mode")
    )

    let decision = policy.nextDecision(
        for: optional,
        attempts: [],
        restartState: .empty,
        now: repairStart
    )

    #expect(decision == .degraded(
        capability: "context-mode",
        failure: .mcpHost,
        recordedAt: repairStart
    ))
}

@Test func repairActionsEscalateInSmallestFirstOrder() {
    let policy = RepairPolicy(configuration: .test)
    let toolFailure = incident(family: .tool)
    let history = [
        attempt(.reloadToolHost, changedVariable: "reload tool", result: .failed),
        attempt(.steerAffectedTurn, changedVariable: "steer affected turn", result: .failed),
        attempt(.reconnectControlPlane, changedVariable: "new control connection", result: .failed),
    ]

    #expect(policy.nextDecision(
        for: toolFailure,
        attempts: [],
        restartState: .empty,
        now: repairStart
    ) == .perform(.reloadToolHost, attemptDeadline: repairStart.addingTimeInterval(5)))
    #expect(policy.nextDecision(
        for: toolFailure,
        attempts: history,
        restartState: .empty,
        now: repairStart.addingTimeInterval(1)
    ) == .perform(.restartDesktop, attemptDeadline: repairStart.addingTimeInterval(6)))
}
