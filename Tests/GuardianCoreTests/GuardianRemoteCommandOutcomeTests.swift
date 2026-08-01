import CryptoKit
import Foundation
import GRDB
import GuardianCore
import Testing

private let outcomeNow = Date(timeIntervalSince1970: 7_000)
private let outcomeGeneration: Int64 = 23

@Test func acceptedRemoteCommandStaysPendingAndOfflineDuplicateReturnsSameOutcome() async throws {
    let fixture = try commandOutcomeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let router = GuardianRemoteRequestRouter(
        gateway: fixture.gateway,
        snapshotProvider: {
            Issue.record("A prompt command must not request an observation snapshot")
            throw CommandOutcomeFixtureError.unexpectedSnapshot
        }
    )
    let packet = try commandOutcomePacket(fixture: fixture)
    let firstRequest = GuardianRemoteWireRequest(
        protocolVersion: .current,
        requestID: UUID(uuidString: "F2000000-0000-0000-0000-000000000001")!,
        body: .command(packet)
    )
    let retryRequest = GuardianRemoteWireRequest(
        protocolVersion: .current,
        requestID: UUID(uuidString: "F2000000-0000-0000-0000-000000000002")!,
        body: .command(packet)
    )

    let firstResponse = try await router.handle(
        firstRequest,
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(2)
    )
    let retryResponse = try await router.handle(
        retryRequest,
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(3)
    )

    guard case let .commandOutcome(firstOutcome) = firstResponse.body,
          case let .commandOutcome(retryOutcome) = retryResponse.body else {
        Issue.record("Durable acceptance must be represented as an explicit command outcome")
        return
    }
    let persistedReceipt = try #require(
        try fixture.journal.remoteReceipt(commandID: fixture.command.commandID)
    )
    #expect(firstOutcome.receipt == persistedReceipt)
    #expect(firstOutcome.state == .pending)
    #expect(retryOutcome == firstOutcome)
}

@Test func terminalCommandOutcomesRemainDistinctAndPreserveAcceptanceReceipt() throws {
    let receipt = commandOutcomeReceipt()
    let appliedAt = outcomeNow.addingTimeInterval(10)
    let failedAt = outcomeNow.addingTimeInterval(11)
    let pending = GuardianRemoteCommandOutcome(receipt: receipt, state: .pending)
    let applied = GuardianRemoteCommandOutcome(
        receipt: receipt,
        state: .applied(at: appliedAt)
    )
    let failed = GuardianRemoteCommandOutcome(
        receipt: receipt,
        state: .failed(code: .adapterUnavailable, at: failedAt)
    )
    let indeterminate = GuardianRemoteCommandOutcome(
        receipt: receipt,
        state: .indeterminate(code: .ambiguousEffect, at: failedAt.addingTimeInterval(1))
    )

    #expect(pending != applied)
    #expect(applied != failed)
    #expect(failed != indeterminate)
    #expect(pending.receipt == receipt)
    #expect(applied.receipt == receipt)
    #expect(failed.receipt == receipt)
    #expect(indeterminate.receipt == receipt)

    let codec = GuardianRemoteWireCodec()
    for (index, outcome) in [pending, applied, failed, indeterminate].enumerated() {
        let response = GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: UUID(),
            body: .commandOutcome(outcome)
        )
        let decoded = try codec.decodeResponse(codec.encode(response))
        guard case let .commandOutcome(decodedOutcome) = decoded.body else {
            Issue.record("Command outcome \(index) lost its explicit wire state")
            continue
        }
        #expect(decodedOutcome == outcome)
        #expect(decodedOutcome.receipt == receipt)
    }
}

@Test func terminalOutcomeIsDurableIdempotentAndCannotBeRewritten() async throws {
    let fixture = try commandOutcomeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let packet = try commandOutcomePacket(fixture: fixture)
    guard case .reconciled(.accepted) = try await fixture.gateway.handle(
        packet,
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(2)
    ) else {
        Issue.record("Command was not accepted")
        return
    }
    let lease = try #require(try fixture.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(3),
        leaseDuration: 20
    ))

    let terminalAt = outcomeNow.addingTimeInterval(10)
    let applied = try fixture.journal.completeRemoteCommand(
        lease,
        completion: .applied,
        at: terminalAt
    )
    #expect(applied.state == .applied(at: terminalAt))

    let reopened = try GuardianJournal(
        databaseURL: fixture.directory.appending(path: "guardian.sqlite")
    )
    #expect(try reopened.completeRemoteCommand(
        lease,
        completion: .applied,
        at: terminalAt.addingTimeInterval(1)
    ) == applied)
    let audits = try reopened.remoteAuditEvents(limit: 20)
    #expect(audits.filter { $0.kind == .commandApplied }.count == 1)
    #expect(audits.allSatisfy { $0.kind != .commandFailed })
    #expect(throws: GuardianJournalError.remoteCommandOutcomeConflict(
        fixture.command.commandID
    )) {
        try reopened.completeRemoteCommand(
            lease,
            completion: .failed(.executionFailed),
            at: terminalAt.addingTimeInterval(2)
        )
    }
    #expect(try reopened.remoteCommandPayload(
        commandID: fixture.command.commandID
    ) != nil)
    let acknowledgement = try reopened.ackRemoteCommandOutcome(
        deviceID: fixture.device.id,
        commandID: fixture.command.commandID,
        at: terminalAt.addingTimeInterval(3)
    )
    #expect(acknowledgement.outcomeVersion == 2)
    #expect(try reopened.remoteCommandPayload(
        commandID: fixture.command.commandID
    ) == nil)
    #expect(try reopened.ackRemoteCommandOutcome(
        deviceID: fixture.device.id,
        commandID: fixture.command.commandID,
        at: terminalAt.addingTimeInterval(4)
    ) == acknowledgement)
    #expect(try reopened.remoteAuditEvents(limit: 30).filter {
        $0.kind == .commandOutcomeAcknowledged
            && $0.commandID == fixture.command.commandID
    }.count == 1)
}

@Test func authenticatedReconnectAcknowledgesTerminalOutcomeAndShredsPayload() async throws {
    let fixture = try commandOutcomeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    guard case .reconciled(.accepted) = try await fixture.gateway.handle(
        try commandOutcomePacket(fixture: fixture),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(2)
    ) else {
        Issue.record("Prompt command was not accepted")
        return
    }
    let lease = try #require(try fixture.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(3),
        leaseDuration: 20
    ))
    _ = try fixture.journal.completeRemoteCommand(
        lease,
        completion: .applied,
        at: outcomeNow.addingTimeInterval(4)
    )
    #expect(try fixture.journal.remoteCommandPayload(
        commandID: fixture.command.commandID
    ) != nil)

    let snapshot = GuardianIPCFullSnapshot(
        protocolVersion: .current,
        generation: outcomeGeneration,
        lastSequence: 0,
        capturedAt: outcomeNow.addingTimeInterval(5),
        operations: [],
        tasks: [],
        taskInventoryCompleteness: .complete
    )
    let router = GuardianRemoteRequestRouter(
        gateway: fixture.gateway,
        snapshotProvider: { snapshot }
    )
    let observeCommandID = UUID(uuidString: "C2000000-0000-0000-0000-000000000003")!
    let payload = try JSONEncoder().encode(GuardianRemoteObserveRequest(
        cursor: nil,
        maximumEvents: 100,
        acknowledgedCommandIDs: [fixture.command.commandID]
    ))
    let observePacket = try commandOutcomeObservePacket(
        fixture: fixture,
        commandID: observeCommandID,
        payload: payload
    )

    let first = try await router.handle(
        .init(protocolVersion: .current, requestID: UUID(), body: .command(observePacket)),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(5)
    )
    let duplicate = try await router.handle(
        .init(protocolVersion: .current, requestID: UUID(), body: .command(observePacket)),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(6)
    )

    guard case let .observation(firstObservation) = first.body,
          case let .observation(duplicateObservation) = duplicate.body else {
        Issue.record("Authenticated reconnect must return observation plus ACK receipts")
        return
    }
    #expect(firstObservation.acknowledgements.count == 1)
    #expect(firstObservation.acknowledgements == duplicateObservation.acknowledgements)
    #expect(firstObservation.acknowledgements.first?.commandID == fixture.command.commandID)
    #expect(firstObservation.acknowledgements.first?.outcomeVersion == 2)
    #expect(try fixture.journal.remoteCommandPayload(
        commandID: fixture.command.commandID
    ) == nil)
    #expect(try fixture.journal.remoteAuditEvents(limit: 30).filter {
        $0.kind == .commandOutcomeAcknowledged
            && $0.commandID == fixture.command.commandID
    }.count == 1)
}

@Test func reconnectAcknowledgementBatchIsAtomic() async throws {
    let fixture = try commandOutcomeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    guard case .reconciled(.accepted) = try await fixture.gateway.handle(
        try commandOutcomePacket(fixture: fixture),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(2)
    ) else {
        Issue.record("Prompt command was not accepted")
        return
    }
    let lease = try #require(try fixture.journal.claimNextRemoteCommand(
        ownerID: UUID(),
        currentDaemonGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(3),
        leaseDuration: 20
    ))
    _ = try fixture.journal.completeRemoteCommand(
        lease,
        completion: .applied,
        at: outcomeNow.addingTimeInterval(4)
    )
    let unknownID = UUID(uuidString: "C2000000-0000-0000-0000-000000000099")!

    do {
        _ = try await fixture.gateway.acknowledgeOutcomes(
            deviceID: fixture.device.id,
            commandIDs: [fixture.command.commandID, unknownID],
            at: outcomeNow.addingTimeInterval(5)
        )
        Issue.record("Mixed-validity ACK batch must fail")
    } catch {
        #expect(error as? GuardianJournalError == .remoteCommandNotFound(unknownID))
    }

    #expect(try fixture.journal.remoteCommandPayload(
        commandID: fixture.command.commandID
    ) != nil)
    #expect(try fixture.journal.remoteAuditEvents(limit: 30).allSatisfy {
        $0.kind != .commandOutcomeAcknowledged
    })
}

@Test func observeResponsesCarryDeviceCommandHistoryOnSnapshotAndEventBatch() async throws {
    let snapshotFixture = try commandOutcomeFixture()
    let eventFixture = try commandOutcomeFixture()
    defer {
        try? FileManager.default.removeItem(at: snapshotFixture.directory)
        try? FileManager.default.removeItem(at: eventFixture.directory)
    }
    for fixture in [snapshotFixture, eventFixture] {
        guard case .reconciled(.accepted) = try await fixture.gateway.handle(
            try commandOutcomePacket(fixture: fixture),
            currentGeneration: outcomeGeneration,
            now: outcomeNow.addingTimeInterval(2)
        ) else {
            Issue.record("Prompt command was not accepted")
            return
        }
    }

    let snapshot = GuardianIPCFullSnapshot(
        protocolVersion: .current,
        generation: outcomeGeneration,
        lastSequence: 0,
        capturedAt: outcomeNow.addingTimeInterval(3),
        operations: [],
        tasks: [],
        taskInventoryCompleteness: .complete
    )
    let snapshotRouter = GuardianRemoteRequestRouter(
        gateway: snapshotFixture.gateway,
        snapshotProvider: { snapshot }
    )
    let snapshotPacket = try commandOutcomeObservePacket(
        fixture: snapshotFixture,
        commandID: UUID(),
        payload: try JSONEncoder().encode(GuardianRemoteObserveRequest(cursor: nil))
    )
    let snapshotResponse = try await snapshotRouter.handle(
        .init(protocolVersion: .current, requestID: UUID(), body: .command(snapshotPacket)),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(3)
    )

    let cursor = GuardianIPCEventCursor(
        generation: outcomeGeneration,
        lastSequence: 0
    )
    let eventRouter = GuardianRemoteRequestRouter(
        gateway: eventFixture.gateway,
        snapshotProvider: {
            Issue.record("Valid event replay must not request a snapshot")
            throw CommandOutcomeFixtureError.unexpectedSnapshot
        },
        eventReplayProvider: { requested, _ in
            .events([], nextCursor: requested)
        }
    )
    let eventPacket = try commandOutcomeObservePacket(
        fixture: eventFixture,
        commandID: UUID(),
        payload: try JSONEncoder().encode(GuardianRemoteObserveRequest(
            cursor: cursor,
            maximumEvents: 100
        ))
    )
    let eventResponse = try await eventRouter.handle(
        .init(protocolVersion: .current, requestID: UUID(), body: .command(eventPacket)),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(3)
    )

    guard case let .observation(observation) = snapshotResponse.body,
          case let .eventBatch(batch) = eventResponse.body else {
        Issue.record("Expected snapshot and event-batch observe paths")
        return
    }
    #expect(observation.commandHistory == batch.commandHistory)
    #expect(observation.commandHistory?.totalCount == 1)
    #expect(observation.commandHistory?.completeness == .complete)
    #expect(observation.commandHistory?.items.first?.action == .prompt)
    #expect(observation.commandHistory?.items.first?.targetThreadID == "command-outcome-thread")
    #expect(observation.commandHistory?.items.first?.outcome.state == .pending)
}

@Test func remoteCommandHistoryIsDeviceScopedAndExcludesObserve() async throws {
    let fixture = try commandOutcomeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    guard case .reconciled(.accepted) = try await fixture.gateway.handle(
        try commandOutcomePacket(fixture: fixture),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(2)
    ) else {
        Issue.record("Prompt command was not accepted")
        return
    }

    let observePayload = Data()
    let observeCommand = commandOutcomeHistoryCommand(
        deviceID: fixture.device.id,
        sequence: 2,
        action: .observe,
        targetThreadID: "guardian:inventory",
        payload: observePayload,
        issuedAt: outcomeNow.addingTimeInterval(3)
    )
    guard case .accepted = try fixture.journal.reconcileRemoteCommand(
        observeCommand,
        sealedPayload: nil,
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(4)
    ) else {
        Issue.record("Observe command was not accepted")
        return
    }

    let other = try pairCommandHistoryDevice(
        in: fixture.journal,
        at: outcomeNow.addingTimeInterval(5)
    )
    let otherPayload = Data("other-device-command".utf8)
    let otherCommand = commandOutcomeHistoryCommand(
        deviceID: other.id,
        sequence: 1,
        action: .prompt,
        targetThreadID: "other-thread",
        payload: otherPayload,
        issuedAt: outcomeNow.addingTimeInterval(6)
    )
    guard case .accepted = try fixture.journal.reconcileRemoteCommand(
        otherCommand,
        sealedPayload: try guardianTestPayloadSealer(
            command: otherCommand,
            payload: otherPayload
        ),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(7)
    ) else {
        Issue.record("Other device command was not accepted")
        return
    }

    let page = try fixture.journal.remoteCommandHistory(
        deviceID: fixture.device.id
    )

    #expect(page.totalCount == 1)
    #expect(page.completeness == .complete)
    #expect(page.items.count == 1)
    let item = try #require(page.items.first)
    #expect(item.action == .prompt)
    #expect(item.targetThreadID == fixture.command.targetThreadID)
    #expect(item.expectedGeneration == fixture.command.expectedGeneration)
    #expect(item.issuedAt == fixture.command.issuedAt)
    #expect(item.deadline == fixture.command.deadline)
    #expect(item.outcome.receipt.commandID == fixture.command.commandID)
    #expect(item.outcome.receipt.deviceID == fixture.device.id)
    #expect(item.outcome.state == .pending)
    #expect(item.outcomeVersion == 1)
    #expect(item.updatedAt == outcomeNow.addingTimeInterval(2))
    let database = try DatabaseQueue(
        path: fixture.directory.appending(path: "guardian.sqlite").path
    )
    let historyRowCount = try await database.read { database in
        try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM guardian_remote_command_history_index"
        )
    }
    #expect(historyRowCount == 2)
}

@Test func remoteCommandHistoryIsBoundedAndExplicitlyTruncated() async throws {
    let fixture = try commandOutcomeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    guard case .reconciled(.accepted) = try await fixture.gateway.handle(
        try commandOutcomePacket(fixture: fixture),
        currentGeneration: outcomeGeneration,
        now: outcomeNow.addingTimeInterval(2)
    ) else {
        Issue.record("Initial command was not accepted")
        return
    }

    var newestCommandID = fixture.command.commandID
    for sequence in 2...101 {
        let payload = Data("history-command-\(sequence)".utf8)
        let command = commandOutcomeHistoryCommand(
            deviceID: fixture.device.id,
            sequence: UInt64(sequence),
            action: .prompt,
            targetThreadID: "history-thread-\(sequence)",
            payload: payload,
            issuedAt: outcomeNow.addingTimeInterval(Double(sequence))
        )
        guard case .accepted = try fixture.journal.reconcileRemoteCommand(
            command,
            sealedPayload: try guardianTestPayloadSealer(
                command: command,
                payload: payload
            ),
            currentGeneration: outcomeGeneration,
            now: outcomeNow.addingTimeInterval(Double(sequence) + 1)
        ) else {
            Issue.record("History command \(sequence) was not accepted")
            return
        }
        newestCommandID = command.commandID
    }

    let page = try fixture.journal.remoteCommandHistory(
        deviceID: fixture.device.id
    )

    #expect(page.items.count == GuardianRemoteCommandHistoryPage.maximumItems)
    #expect(page.totalCount == 101)
    #expect(page.completeness == .truncated)
    #expect(page.items.first?.outcome.receipt.commandID == newestCommandID)
    #expect(page.items.allSatisfy { $0.action != .observe })
    #expect(page.items.allSatisfy { $0.outcome.receipt.deviceID == fixture.device.id })
    #expect(!page.items.contains {
        $0.outcome.receipt.commandID == fixture.command.commandID
    })
}

@Test func remoteCommandHistoryItemRejectsInconsistentSignedMetadata() {
    let receipt = commandOutcomeReceipt()
    let wrongGeneration = GuardianRemoteCommandHistoryItem(
        action: .prompt,
        targetThreadID: "thread-1",
        expectedGeneration: receipt.generation + 1,
        issuedAt: outcomeNow.addingTimeInterval(-1),
        deadline: outcomeNow.addingTimeInterval(20),
        outcome: .init(receipt: receipt, state: .pending),
        outcomeVersion: 1,
        updatedAt: receipt.acceptedAt
    )
    let expiredAtAcceptance = GuardianRemoteCommandHistoryItem(
        action: .prompt,
        targetThreadID: "thread-1",
        expectedGeneration: receipt.generation,
        issuedAt: outcomeNow.addingTimeInterval(-2),
        deadline: outcomeNow.addingTimeInterval(-1),
        outcome: .init(receipt: receipt, state: .pending),
        outcomeVersion: 1,
        updatedAt: receipt.acceptedAt
    )

    #expect(!wrongGeneration.isValid)
    #expect(!expiredAtAcceptance.isValid)
}

private enum CommandOutcomeFixtureError: Error {
    case unexpectedSnapshot
}

private struct CommandOutcomeFixture {
    let directory: URL
    let journal: GuardianJournal
    let gateway: GuardianRemoteGatewayCore
    let deviceKey: Curve25519.Signing.PrivateKey
    let device: GuardianRemoteDevice
    let command: GuardianRemoteCommand
}

private func commandOutcomeFixture() throws -> CommandOutcomeFixture {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "guardian-command-outcome-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = try GuardianJournal(databaseURL: directory.appending(path: "guardian.sqlite"))
    let deviceKey = Curve25519.Signing.PrivateKey()
    let challenge = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: Data(repeating: 0x61, count: 32),
        expiresAt: outcomeNow.addingTimeInterval(60),
        consumedAt: nil
    )
    let device = GuardianRemoteDevice(
        id: UUID(uuidString: "B2000000-0000-0000-0000-000000000001")!,
        publicKey: deviceKey.publicKey.rawRepresentation,
        capabilities: [.observe, .prompt],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: outcomeNow.addingTimeInterval(1),
        lastSeenAt: nil
    )
    try journal.issuePairingChallenge(challenge, issuedAt: outcomeNow)
    try journal.pairRemoteDevice(
        device,
        challenge: challenge,
        at: outcomeNow.addingTimeInterval(1)
    )
    let payload = Data("continue exact task".utf8)
    let command = GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(uuidString: "C2000000-0000-0000-0000-000000000001")!,
        deviceID: device.id,
        expectedGeneration: outcomeGeneration,
        sequence: 1,
        nonce: UUID(uuidString: "D2000000-0000-0000-0000-000000000001")!,
        issuedAt: outcomeNow.addingTimeInterval(1),
        deadline: outcomeNow.addingTimeInterval(30),
        revocationEpoch: device.revocationEpoch,
        targetThreadID: "command-outcome-thread",
        action: .prompt,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
    return CommandOutcomeFixture(
        directory: directory,
        journal: journal,
        gateway: GuardianRemoteGatewayCore(
            journal: journal,
            supportedActions: [.observe, .prompt],
            payloadSealer: { try guardianTestPayloadSealer(command: $0, payload: $1) }
        ),
        deviceKey: deviceKey,
        device: device,
        command: command
    )
}

private func commandOutcomePacket(
    fixture: CommandOutcomeFixture
) throws -> GuardianRemoteCommandPacket {
    let payload = Data("continue exact task".utf8)
    return GuardianRemoteCommandPacket(
        signedCommand: try GuardianRemoteCommandAuthenticator().sign(
            fixture.command,
            using: fixture.deviceKey
        ),
        payload: payload
    )
}

private func commandOutcomeObservePacket(
    fixture: CommandOutcomeFixture,
    commandID: UUID,
    payload: Data
) throws -> GuardianRemoteCommandPacket {
    let command = GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: commandID,
        deviceID: fixture.device.id,
        expectedGeneration: outcomeGeneration,
        sequence: 2,
        nonce: UUID(uuidString: "D2000000-0000-0000-0000-000000000003")!,
        issuedAt: outcomeNow.addingTimeInterval(4),
        deadline: outcomeNow.addingTimeInterval(30),
        revocationEpoch: fixture.device.revocationEpoch,
        targetThreadID: "command-outcome-thread",
        action: .observe,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
    return GuardianRemoteCommandPacket(
        signedCommand: try GuardianRemoteCommandAuthenticator().sign(
            command,
            using: fixture.deviceKey
        ),
        payload: payload
    )
}

private func commandOutcomeReceipt() -> GuardianRemoteReceipt {
    GuardianRemoteReceipt(
        commandID: UUID(uuidString: "C2000000-0000-0000-0000-000000000002")!,
        deviceID: UUID(uuidString: "B2000000-0000-0000-0000-000000000002")!,
        payloadDigest: Data(repeating: 0x72, count: 32),
        generation: outcomeGeneration,
        sequence: 9,
        acceptedAt: outcomeNow
    )
}

private func pairCommandHistoryDevice(
    in journal: GuardianJournal,
    at date: Date
) throws -> GuardianRemoteDevice {
    let key = Curve25519.Signing.PrivateKey()
    let challenge = GuardianPairingChallenge(
        nonce: UUID(),
        guardianIdentityHash: Data(repeating: 0x64, count: 32),
        expiresAt: date.addingTimeInterval(60),
        consumedAt: nil
    )
    let device = GuardianRemoteDevice(
        id: UUID(),
        publicKey: key.publicKey.rawRepresentation,
        capabilities: [.observe, .prompt],
        status: .active,
        pairingEpoch: 1,
        revocationEpoch: 0,
        lastAcceptedSequence: 0,
        pairedAt: date.addingTimeInterval(1),
        lastSeenAt: nil
    )
    try journal.issuePairingChallenge(challenge, issuedAt: date)
    try journal.pairRemoteDevice(
        device,
        challenge: challenge,
        at: date.addingTimeInterval(1)
    )
    return device
}

private func commandOutcomeHistoryCommand(
    deviceID: UUID,
    sequence: UInt64,
    action: GuardianRemoteAction,
    targetThreadID: String,
    payload: Data,
    issuedAt: Date
) -> GuardianRemoteCommand {
    GuardianRemoteCommand(
        protocolVersion: .current,
        commandID: UUID(),
        deviceID: deviceID,
        expectedGeneration: outcomeGeneration,
        sequence: sequence,
        nonce: UUID(),
        issuedAt: issuedAt,
        deadline: outcomeNow.addingTimeInterval(1_000),
        revocationEpoch: 0,
        targetThreadID: targetThreadID,
        action: action,
        force: false,
        payloadDigest: Data(SHA256.hash(data: payload))
    )
}
