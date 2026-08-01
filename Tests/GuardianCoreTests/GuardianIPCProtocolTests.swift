import Foundation
import Testing
@testable import GuardianCore

@Test func defaultLocalRoleCapabilitiesAreLeastPrivilege() {
    #expect(GuardianLocalClientDefaults.maximumCapabilities(for: .cli) == [.observe])
    #expect(GuardianLocalClientDefaults.maximumCapabilities(for: .mcp)
        == [.observe, .nativeRecovery, .hardRecovery])
    #expect(!GuardianLocalClientDefaults.maximumCapabilities(for: .mcp)
        .contains(.forceRestart))
    #expect(!GuardianLocalClientDefaults.maximumCapabilities(for: .mcp)
        .contains(.crossThreadControl))
}

private let ipcOperationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private let ipcClientID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
private let ipcRPCID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
private let ipcNow = Date(timeIntervalSince1970: 1_000)

private func ipcClient(
    role: GuardianIPCClientRole = .macUI,
    capabilities: GuardianIPCCapabilities = [.observe, .nativeRecovery]
) -> GuardianIPCAuthenticatedClient {
    GuardianIPCAuthenticatedClient(
        clientID: ipcClientID,
        role: role,
        capabilities: capabilities,
        authenticatedAt: ipcNow
    )
}

private func ipcCommand(
    expectedGeneration: Int64 = 7,
    deadline: Date = ipcNow.addingTimeInterval(30),
    originThreadID: String = "origin-thread",
    targetThreadID: String = "origin-thread",
    force: Bool = false
) -> GuardianIPCCommand {
    GuardianIPCCommand(
        protocolVersion: .current,
        rpcID: ipcRPCID,
        operationID: ipcOperationID,
        clientID: ipcClientID,
        expectedGeneration: expectedGeneration,
        deadline: deadline,
        originThreadID: originThreadID,
        targetThreadID: targetThreadID,
        action: .recover,
        force: force
    )
}

@Test func ipcProtocolEnvelopeRoundTripsIndependentlyOfJournalSchema() throws {
    let command = ipcCommand()
    let data = try JSONEncoder().encode(command)

    #expect(try JSONDecoder().decode(GuardianIPCCommand.self, from: data) == command)
    #expect(command.protocolVersion == GuardianIPCProtocolVersion(major: 1, minor: 2))
}

@Test func staleGenerationAndExpiredDeadlineAreRejected() {
    let validator = GuardianIPCCommandValidator()

    #expect(
        validator.validate(
            ipcCommand(expectedGeneration: 6),
            from: ipcClient(),
            currentGeneration: 7,
            now: ipcNow
        ) == .failure(.staleGeneration(expected: 6, current: 7))
    )
    #expect(
        validator.validate(
            ipcCommand(deadline: ipcNow),
            from: ipcClient(),
            currentGeneration: 7,
            now: ipcNow
        ) == .failure(.commandExpired)
    )
}

@Test func initialObserveMayDiscoverGenerationButMutationMayNotUseWildcard() {
    let validator = GuardianIPCCommandValidator()
    let observe = GuardianIPCCommand(
        protocolVersion: .current,
        rpcID: ipcRPCID,
        operationID: ipcOperationID,
        clientID: ipcClientID,
        expectedGeneration: 0,
        deadline: ipcNow.addingTimeInterval(30),
        originThreadID: "origin-thread",
        targetThreadID: "origin-thread",
        action: .observe,
        force: false
    )

    #expect(validator.validate(
        observe,
        from: ipcClient(capabilities: [.observe]),
        currentGeneration: 7,
        now: ipcNow
    ) == .success)
    #expect(validator.validate(
        ipcCommand(expectedGeneration: 0),
        from: ipcClient(),
        currentGeneration: 7,
        now: ipcNow
    ) == .failure(.staleGeneration(expected: 0, current: 7)))
}

@Test func mcpCannotClaimCrossThreadOrForceAuthority() {
    let overprivilegedMCP = ipcClient(
        role: .mcp,
        capabilities: [.observe, .nativeRecovery, .crossThreadControl, .forceRestart]
    )
    let validator = GuardianIPCCommandValidator()

    #expect(
        validator.validate(
            ipcCommand(targetThreadID: "other-thread"),
            from: overprivilegedMCP,
            currentGeneration: 7,
            now: ipcNow
        ) == .failure(.roleCannotControlOtherThread(.mcp))
    )
    #expect(
        validator.validate(
            ipcCommand(force: true),
            from: overprivilegedMCP,
            currentGeneration: 7,
            now: ipcNow
        ) == .failure(.roleCannotForce(.mcp))
    )
}

@Test func capabilitySetAndAuthenticatedClientIdentityAreEnforced() {
    let validator = GuardianIPCCommandValidator()

    #expect(
        validator.validate(
            ipcCommand(),
            from: ipcClient(capabilities: [.observe]),
            currentGeneration: 7,
            now: ipcNow
        ) == .failure(.missingCapability(.nativeRecovery))
    )
    let otherClient = GuardianIPCAuthenticatedClient(
        clientID: UUID(),
        role: .cli,
        capabilities: [.nativeRecovery],
        authenticatedAt: ipcNow
    )
    #expect(
        validator.validate(
            ipcCommand(),
            from: otherClient,
            currentGeneration: 7,
            now: ipcNow
        ) == .failure(.clientIdentityMismatch)
    )
}

@Test func orderedEventsDetectGapAndDemandFullSnapshot() {
    let cursor = GuardianIPCEventCursor(generation: 7, lastSequence: 10)
    let contiguous = GuardianIPCEvent(
        generation: 7,
        sequence: 11,
        operationID: ipcOperationID,
        emittedAt: ipcNow,
        kind: .operationChanged
    )
    let gap = GuardianIPCEvent(
        generation: 7,
        sequence: 12,
        operationID: ipcOperationID,
        emittedAt: ipcNow,
        kind: .operationChanged
    )

    #expect(GuardianIPCEventValidator.assess(contiguous, after: cursor) == .accepted)
    #expect(
        GuardianIPCEventValidator.assess(gap, after: cursor)
            == .snapshotRequired(.sequenceGap(expected: 11, received: 12))
    )
}

@Test func generationChangeDemandsSnapshotEvenWhenSequenceLooksContiguous() {
    let cursor = GuardianIPCEventCursor(generation: 7, lastSequence: 10)
    let event = GuardianIPCEvent(
        generation: 8,
        sequence: 11,
        operationID: ipcOperationID,
        emittedAt: ipcNow,
        kind: .daemonGenerationChanged
    )

    #expect(
        GuardianIPCEventValidator.assess(event, after: cursor)
            == .snapshotRequired(.generationChanged(expected: 7, received: 8))
    )
}

@Test func fullSnapshotCarriesGenerationAndLastSequence() throws {
    let snapshot = GuardianIPCFullSnapshot(
        protocolVersion: .current,
        generation: 9,
        lastSequence: 42,
        capturedAt: ipcNow,
        operations: [
            GuardianIPCOperationSnapshot(
                operationID: ipcOperationID,
                originThreadID: "origin-thread",
                phase: "monitoring"
            ),
        ]
    )

    let decoded = try JSONDecoder().decode(
        GuardianIPCFullSnapshot.self,
        from: JSONEncoder().encode(snapshot)
    )
    #expect(decoded == snapshot)
    #expect(decoded.cursor == GuardianIPCEventCursor(generation: 9, lastSequence: 42))
}

@Test func disconnectExpiresOnlyMatchingOpenRPCsDeterministically() {
    let otherClientID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
    let matching = GuardianIPCInFlightRPC(
        rpcID: ipcRPCID,
        operationID: ipcOperationID,
        clientID: ipcClientID,
        deadline: ipcNow.addingTimeInterval(30),
        state: .open
    )
    let unrelated = GuardianIPCInFlightRPC(
        rpcID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
        operationID: UUID(),
        clientID: otherClientID,
        deadline: ipcNow.addingTimeInterval(30),
        state: .open
    )

    let reduced = GuardianIPCDisconnectReducer.expireOpenRPCs(
        ownedBy: ipcClientID,
        at: ipcNow,
        in: [unrelated, matching]
    )

    #expect(reduced.map(\.rpcID) == [ipcRPCID, unrelated.rpcID])
    #expect(reduced[0].state == .expired(reason: .clientDisconnected, at: ipcNow))
    #expect(reduced[1] == unrelated)
}
