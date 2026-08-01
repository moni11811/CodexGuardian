import GuardianCore
import Testing

private let ownedProcess = GuardianAgentProcessIdentity(
    processID: 410,
    processStartIdentity: 9_001
)

private let ownedResource = GuardianAgentResourceOwnership(
    taskID: "task-a",
    canonicalWorktreePath: "/repo/task-a",
    process: ownedProcess
)

private func request(
    _ capability: GuardianAgentCapability,
    taskID: String = "task-a",
    worktree: String = "/repo/task-a",
    process: GuardianAgentProcessIdentity = ownedProcess
) -> GuardianAgentActionRequest {
    GuardianAgentActionRequest(
        capability: capability,
        target: GuardianAgentResourceOwnership(
            taskID: taskID,
            canonicalWorktreePath: worktree,
            process: process
        )
    )
}

private func semanticACP(
    _ capabilities: Set<GuardianAgentCapability>
) -> GuardianAgentAdapterManifest {
    GuardianAgentAdapterManifest(
        identity: GuardianAdapterIdentity(id: "acp-agent", version: "1"),
        transport: .semanticACP,
        declaredCapabilities: capabilities
    )
}

@Test func unsupportedSemanticCapabilityNeverBecomesActionable() {
    let adapter = semanticACP([.observe, .prompt])

    #expect(GuardianAgentAdapterPolicy().evaluate(
        request(.approve),
        adapter: adapter,
        ownership: ownedResource
    ) == .denied(.unsupportedCapability(.approve)))
    #expect(adapter.effectiveCapabilities == [.observe, .prompt])
}

@Test func ptyHeuristicIsObserveOnlyAndNeverProvidesDestructiveAuthority() {
    let adapter = GuardianAgentAdapterManifest(
        identity: GuardianAdapterIdentity(id: "pty-fallback", version: "1"),
        transport: .ptyHeuristic,
        declaredCapabilities: [.observe, .prompt, .repair, .hardRecover]
    )

    #expect(adapter.effectiveCapabilities == [.observe])
    #expect(adapter.canProvideDestructiveAuthority == false)
    #expect(GuardianAgentAdapterPolicy().evaluate(
        request(.observe),
        adapter: adapter,
        ownership: ownedResource
    ) == .allowed(.observationOnly))
    #expect(GuardianAgentAdapterPolicy().evaluate(
        request(.repair),
        adapter: adapter,
        ownership: ownedResource
    ) == .denied(.heuristicObserveOnly))
}

@Test func taskOwnershipMismatchIsDenied() {
    #expect(GuardianAgentAdapterPolicy().evaluate(
        request(.prompt, taskID: "task-b"),
        adapter: semanticACP([.prompt]),
        ownership: ownedResource
    ) == .denied(.taskOwnershipMismatch))
}

@Test func worktreeOwnershipMismatchIsDenied() {
    #expect(GuardianAgentAdapterPolicy().evaluate(
        request(.prompt, worktree: "/repo/task-b"),
        adapter: semanticACP([.prompt]),
        ownership: ownedResource
    ) == .denied(.worktreeOwnershipMismatch))
}

@Test func processOwnershipMismatchIsDeniedEvenWhenPidIsReused() {
    let reusedPID = GuardianAgentProcessIdentity(
        processID: ownedProcess.processID,
        processStartIdentity: ownedProcess.processStartIdentity + 1
    )

    #expect(GuardianAgentAdapterPolicy().evaluate(
        request(.prompt, process: reusedPID),
        adapter: semanticACP([.prompt]),
        ownership: ownedResource
    ) == .denied(.processOwnershipMismatch))
}

@Test func semanticACPExposesOnlyDeclaredCapabilities() {
    let adapter = semanticACP([.observe, .prompt, .interrupt])

    #expect(adapter.canProvideDestructiveAuthority)
    #expect(GuardianAgentAdapterPolicy().evaluate(
        request(.prompt),
        adapter: adapter,
        ownership: ownedResource
    ) == .allowed(.semanticAuthority))
    #expect(GuardianAgentAdapterPolicy().evaluate(
        request(.repair),
        adapter: adapter,
        ownership: ownedResource
    ) == .denied(.unsupportedCapability(.repair)))
}
