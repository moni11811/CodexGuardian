import Foundation
import Testing
@testable import GuardianCore

@Test func daemonBindsCredentialToServerAssignedRoleAndShadowMode() async throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    try journal.storeTaskSnapshot(GuardianStoredTaskSnapshot(
        threadID: "thread-approval",
        state: .waitingUser,
        source: .appServerEvent,
        serverGeneration: 9,
        eventSequence: 42,
        confidence: 1,
        observedAt: Date(timeIntervalSince1970: 100),
        expiresAt: Date(timeIntervalSince1970: 130),
        inventoryCompleteness: .complete
    ))
    let clientID = UUID()
    let credential = Data(repeating: 0xA5, count: 32)
    let registration = GuardianLocalClientRegistration(
        credential: credential,
        client: GuardianIPCAuthenticatedClient(
            clientID: clientID,
            role: .mcp,
            capabilities: [.observe, .nativeRecovery],
            authenticatedAt: Date(timeIntervalSince1970: 100)
        )
    )
    let daemon = try GuardianDaemonRuntime.start(
        journal: journal,
        registeredClients: [registration],
        mode: .shadowOnly,
        at: Date(timeIntervalSince1970: 100)
    )
    let generation = await daemon.generation
    #expect(try journal.nextDaemonEventSequence(
        expectedGeneration: generation,
        at: Date(timeIntervalSince1970: 100.5)
    ) == 1)
    let observe = GuardianIPCCommand(
        protocolVersion: .current,
        rpcID: UUID(),
        operationID: UUID(),
        clientID: clientID,
        expectedGeneration: generation,
        deadline: Date(timeIntervalSince1970: 110),
        originThreadID: "thread-1",
        targetThreadID: "thread-1",
        action: .observe,
        force: false
    )

    let snapshotReply = await daemon.handle(
        GuardianDaemonRequest(credential: credential, command: observe),
        now: Date(timeIntervalSince1970: 101)
    )
    guard case let .snapshot(snapshot) = snapshotReply else {
        Issue.record("Expected authenticated snapshot")
        return
    }
    #expect(snapshot.generation == generation)
    #expect(snapshot.lastSequence == 1)
    #expect(snapshot.taskInventoryCompleteness == .complete)
    #expect(snapshot.tasks == [GuardianIPCTaskSnapshot(
        threadID: "thread-approval",
        state: .waitingUser,
        reason: .coherentEvidence,
        serverGeneration: 9,
        eventSequence: 42,
        confidence: 1,
        expiresAt: Date(timeIntervalSince1970: 130)
    )])

    let unauthorized = await daemon.handle(
        GuardianDaemonRequest(credential: Data(repeating: 0x00, count: 32), command: observe),
        now: Date(timeIntervalSince1970: 101)
    )
    #expect(unauthorized == .rejected(.unauthorizedClient))

    let recover = GuardianIPCCommand(
        protocolVersion: .current,
        rpcID: UUID(),
        operationID: UUID(),
        clientID: clientID,
        expectedGeneration: generation,
        deadline: Date(timeIntervalSince1970: 110),
        originThreadID: "thread-1",
        targetThreadID: "thread-1",
        action: .recover,
        force: false
    )
    #expect(await daemon.handle(
        GuardianDaemonRequest(credential: credential, command: recover),
        now: Date(timeIntervalSince1970: 101)
    ) == .rejected(.shadowMode))
}

@Test func remoteGatewayUsesDaemonOwnedSnapshotWithoutForgingLocalCredentials() async throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let daemon = try GuardianDaemonRuntime.start(
        journal: journal,
        registeredClients: [GuardianLocalClientRegistration(
            credential: Data(repeating: 0xA5, count: 32),
            client: GuardianIPCAuthenticatedClient(
                clientID: UUID(),
                role: .macUI,
                capabilities: [.observe],
                authenticatedAt: Date(timeIntervalSince1970: 100)
            )
        )],
        mode: .shadowOnly,
        at: Date(timeIntervalSince1970: 100)
    )

    let snapshot = try await daemon.currentSnapshot(now: Date(timeIntervalSince1970: 101))
    let generation = await daemon.generation

    #expect(snapshot.generation == generation)
    #expect(snapshot.taskInventoryCompleteness == .incomplete)
}

@Test func daemonSnapshotCarriesCanonicalOperationHistory() async throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let operation = GuardianOperation(
        id: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
        kind: .nativeRecovery,
        originThreadID: "exact-thread",
        originTokenHash: "history-origin",
        phase: .prepared,
        createdAt: Date(timeIntervalSince1970: 90),
        updatedAt: Date(timeIntervalSince1970: 91)
    )
    _ = try journal.create(operation)
    let daemon = try GuardianDaemonRuntime.start(
        journal: journal,
        registeredClients: [GuardianLocalClientRegistration(
            credential: Data(repeating: 0xA5, count: 32),
            client: GuardianIPCAuthenticatedClient(
                clientID: UUID(),
                role: .macUI,
                capabilities: [.observe],
                authenticatedAt: Date(timeIntervalSince1970: 100)
            )
        )],
        mode: .shadowOnly,
        at: Date(timeIntervalSince1970: 100)
    )

    let snapshot = try await daemon.currentSnapshot(now: Date(timeIntervalSince1970: 101))

    #expect(snapshot.operationHistory?.items == [GuardianIPCOperationHistoryItem(
        operationID: operation.id,
        kind: operation.kind,
        originThreadID: operation.originThreadID,
        phase: operation.phase,
        createdAt: operation.createdAt,
        updatedAt: operation.updatedAt
    )])
    #expect(snapshot.operationHistory?.completeness == .complete)
}

@Test func daemonSnapshotBoundsHistoryWithoutClaimingItIsComplete() async throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    for index in 0...GuardianIPCOperationHistoryPage.maximumItems {
        _ = try journal.create(GuardianOperation(
            id: UUID(),
            kind: .nativeRecovery,
            originThreadID: "thread-\(index)",
            originTokenHash: "history-\(index)",
            phase: .prepared,
            createdAt: Date(timeIntervalSince1970: Double(index + 1)),
            updatedAt: Date(timeIntervalSince1970: Double(index + 1))
        ))
    }
    let daemon = try GuardianDaemonRuntime.start(
        journal: journal,
        registeredClients: [],
        mode: .shadowOnly,
        at: Date(timeIntervalSince1970: 1_000)
    )

    let snapshot = try await daemon.currentSnapshot(now: Date(timeIntervalSince1970: 1_001))
    let history = try #require(snapshot.operationHistory)

    #expect(history.items.count == GuardianIPCOperationHistoryPage.maximumItems)
    #expect(history.totalCount == GuardianIPCOperationHistoryPage.maximumItems + 1)
    #expect(history.completeness == .truncated)
    #expect(history.items.first?.originThreadID == "thread-1")
}

@Test func duplicateCredentialOrClientIdentityFailsClosed() throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let credential = Data(repeating: 0xA5, count: 32)
    let client = GuardianIPCAuthenticatedClient(
        clientID: UUID(),
        role: .mcp,
        capabilities: [.observe],
        authenticatedAt: Date(timeIntervalSince1970: 100)
    )
    let duplicateCredential = GuardianLocalClientRegistration(
        credential: credential,
        client: GuardianIPCAuthenticatedClient(
            clientID: UUID(),
            role: .cli,
            capabilities: [.observe],
            authenticatedAt: Date(timeIntervalSince1970: 100)
        )
    )
    #expect(throws: GuardianDaemonRuntimeError.duplicateCredential) {
        try GuardianDaemonRuntime.start(
            journal: GuardianJournal(databaseURL: databaseURL),
            registeredClients: [
                GuardianLocalClientRegistration(credential: credential, client: client),
                duplicateCredential,
            ],
            mode: .shadowOnly,
            at: Date(timeIntervalSince1970: 100)
        )
    }

    #expect(throws: GuardianDaemonRuntimeError.duplicateClientID) {
        try GuardianDaemonRuntime.start(
            journal: GuardianJournal(databaseURL: databaseURL),
            registeredClients: [
                GuardianLocalClientRegistration(credential: credential, client: client),
                GuardianLocalClientRegistration(
                    credential: Data(repeating: 0xB5, count: 32),
                    client: client
                ),
            ],
            mode: .shadowOnly,
            at: Date(timeIntervalSince1970: 100)
        )
    }
}

@Test func daemonCannotSelfDeclareAuthorityBeforeDurableCutover() throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let credential = Data(repeating: 0xA5, count: 32)
    let registration = GuardianLocalClientRegistration(
        credential: credential,
        client: GuardianIPCAuthenticatedClient(
            clientID: UUID(),
            role: .macUI,
            capabilities: [.observe, .hardRecovery, .forceRestart],
            authenticatedAt: Date(timeIntervalSince1970: 100)
        ),
        peerPolicy: GuardianLocalPeerPolicy(
            role: .macUI,
            executablePath: "/Applications/Codex Guardian.app/Contents/MacOS/CodexGuardian",
            signingIdentifier: "com.moni.codexguardian",
            teamIdentifier: "GUARDIANTEAM",
            requiresHardenedRuntime: true
        )
    )

    #expect(throws: GuardianDaemonRuntimeError.authorityNotGranted) {
        try GuardianDaemonRuntime.start(
            journal: journal,
            registeredClients: [registration],
            mode: .authoritative,
            at: Date(timeIntervalSince1970: 100)
        )
    }
    #expect(try journal.authorityFence().phase == .legacyAuthoritative)
}

@Test func authoritativeDaemonRejectsCredentialOnlyClientBeforeAuthorityLookup() throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let registration = GuardianLocalClientRegistration(
        credential: Data(repeating: 0xA5, count: 32),
        client: GuardianIPCAuthenticatedClient(
            clientID: UUID(),
            role: .macUI,
            capabilities: [.observe, .hardRecovery, .forceRestart],
            authenticatedAt: Date(timeIntervalSince1970: 100)
        )
    )

    #expect(throws: GuardianDaemonRuntimeError.invalidPeerPolicy) {
        try GuardianDaemonRuntime.start(
            journal: GuardianJournal(databaseURL: databaseURL),
            registeredClients: [registration],
            mode: .authoritative,
            at: Date(timeIntervalSince1970: 100)
        )
    }
}

@Test func daemonSnapshotExposesNamedOperationReadiness() async throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let operation = GuardianOperation(
        id: UUID(),
        kind: .hardRestart,
        originThreadID: "exact-thread",
        originTokenHash: "readiness-snapshot-origin",
        phase: .controlReady,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 101)
    )
    _ = try journal.create(GuardianOperation(
        id: operation.id,
        kind: operation.kind,
        originThreadID: operation.originThreadID,
        originTokenHash: operation.originTokenHash,
        phase: .prepared,
        createdAt: operation.createdAt,
        updatedAt: operation.createdAt
    ))
    let lease = try journal.acquireLease(
        resource: "desktop-restart",
        ownerID: operation.id,
        now: Date(timeIntervalSince1970: 100),
        duration: 30
    )
    try journal.transition(
        operationID: operation.id,
        expectedPhase: .prepared,
        to: .gated,
        lease: lease,
        at: Date(timeIntervalSince1970: 100.2)
    )
    let identity = GuardianDesktopProcessIdentity(
        bundleIdentifier: "com.openai.codex",
        bundleURLPath: "/Applications/Codex.app",
        signingIdentifier: "com.openai.codex",
        teamIdentifier: "OPENAI",
        processID: 1234,
        processStartIdentity: 88,
        serverGeneration: 7
    )
    try journal.storeRestartFence(
        operationID: operation.id,
        identity: identity,
        lease: lease,
        at: Date(timeIntervalSince1970: 100.3)
    )
    _ = try journal.issueRestart(
        operationID: operation.id,
        observedIdentity: identity,
        lease: lease,
        at: Date(timeIntervalSince1970: 100.4)
    )
    try journal.transition(
        operationID: operation.id,
        expectedPhase: .restartIssued,
        to: .desktopStarted,
        lease: lease,
        at: Date(timeIntervalSince1970: 100.5)
    )
    try journal.transition(
        operationID: operation.id,
        expectedPhase: .desktopStarted,
        to: .controlReady,
        lease: lease,
        at: Date(timeIntervalSince1970: 100.6)
    )
    try journal.replaceReadinessManifest(operationID: operation.id, records: [
        GuardianCapabilityRecord(
            capability: "control.ready",
            requirement: .required,
            state: .ready,
            evidenceID: "control-evidence",
            observedAt: Date(timeIntervalSince1970: 100),
            deadline: Date(timeIntervalSince1970: 110)
        ),
        GuardianCapabilityRecord(
            capability: "plugin.context-mode",
            requirement: .optional,
            state: .failed,
            evidenceID: "plugin-evidence",
            observedAt: Date(timeIntervalSince1970: 100),
            deadline: Date(timeIntervalSince1970: 110)
        ),
    ])
    let clientID = UUID()
    let credential = Data(repeating: 0xA5, count: 32)
    let daemon = try GuardianDaemonRuntime.start(
        journal: journal,
        registeredClients: [GuardianLocalClientRegistration(
            credential: credential,
            client: GuardianIPCAuthenticatedClient(
                clientID: clientID,
                role: .macUI,
                capabilities: [.observe],
                authenticatedAt: Date(timeIntervalSince1970: 100)
            )
        )],
        mode: .shadowOnly,
        at: Date(timeIntervalSince1970: 101)
    )
    let generation = await daemon.generation
    let reply = await daemon.handle(GuardianDaemonRequest(
        credential: credential,
        command: GuardianIPCCommand(
            protocolVersion: .current,
            rpcID: UUID(),
            operationID: UUID(),
            clientID: clientID,
            expectedGeneration: generation,
            deadline: Date(timeIntervalSince1970: 110),
            originThreadID: "mac-ui",
            targetThreadID: "mac-ui",
            action: .observe,
            force: false
        )
    ), now: Date(timeIntervalSince1970: 105))

    guard case let .snapshot(snapshot) = reply else {
        Issue.record("Expected daemon snapshot")
        return
    }
    #expect(snapshot.operations.first?.readiness
        == .ready(degraded: ["plugin.context-mode"]))
}

@Test func stolenLocalCredentialCannotBypassInstallBoundPeerPolicy() async throws {
    let databaseURL = try daemonRuntimeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let journal = try GuardianJournal(databaseURL: databaseURL)
    let clientID = UUID()
    let credential = Data(repeating: 0xA5, count: 32)
    let policy = GuardianLocalPeerPolicy(
        role: .macUI,
        executablePath: "/Applications/Codex Guardian.app/Contents/MacOS/CodexGuardian",
        signingIdentifier: "com.moni.codexguardian",
        teamIdentifier: "GUARDIANTEAM",
        requiresHardenedRuntime: true
    )
    let daemon = try GuardianDaemonRuntime.start(
        journal: journal,
        registeredClients: [GuardianLocalClientRegistration(
            credential: credential,
            client: GuardianIPCAuthenticatedClient(
                clientID: clientID,
                role: .macUI,
                capabilities: [.observe],
                authenticatedAt: Date(timeIntervalSince1970: 100)
            ),
            peerPolicy: policy
        )],
        mode: .shadowOnly,
        at: Date(timeIntervalSince1970: 100)
    )
    let generation = await daemon.generation
    let request = GuardianDaemonRequest(
        credential: credential,
        command: GuardianIPCCommand(
            protocolVersion: .current,
            rpcID: UUID(),
            operationID: UUID(),
            clientID: clientID,
            expectedGeneration: generation,
            deadline: Date(timeIntervalSince1970: 110),
            originThreadID: "local-ui",
            targetThreadID: "local-ui",
            action: .observe,
            force: false
        )
    )
    let foreignPeer = GuardianVerifiedLocalPeer(
        auditTokenHash: Data(repeating: 0x11, count: 32),
        executablePath: "/tmp/CodexGuardian",
        signingIdentifier: "evil.helper",
        teamIdentifier: "ATTACKER",
        hardenedRuntime: false
    )
    let exactPeer = GuardianVerifiedLocalPeer(
        auditTokenHash: Data(repeating: 0x22, count: 32),
        executablePath: policy.executablePath,
        signingIdentifier: policy.signingIdentifier,
        teamIdentifier: policy.teamIdentifier,
        hardenedRuntime: true
    )

    #expect(await daemon.handle(request, verifiedPeer: nil, now: Date(timeIntervalSince1970: 101))
        == .rejected(.unauthorizedClient))
    #expect(await daemon.handle(
        request,
        verifiedPeer: foreignPeer,
        now: Date(timeIntervalSince1970: 101)
    ) == .rejected(.unauthorizedClient))
    guard case .snapshot = await daemon.handle(
        request,
        verifiedPeer: exactPeer,
        now: Date(timeIntervalSince1970: 101)
    ) else {
        Issue.record("Expected exact install-bound peer to observe")
        return
    }
    #expect(try journal.operations().isEmpty)
}

private func daemonRuntimeDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "guardian-daemon-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "guardian.sqlite")
}
