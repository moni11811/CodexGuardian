import CryptoKit
import Foundation
import GuardianCore
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone operational remote codec")
struct GuardianPhoneRemoteCodecTests {
    private let now = Date(timeIntervalSince1970: 9_000)
    private let requestID = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
    private let commandID = UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
    private let nonce = UUID(uuidString: "80000000-0000-0000-0000-000000000003")!

    @Test("phone signed observe frame is accepted by the Mac wire and signature contract")
    func observeFrameMatchesMacContract() throws {
        let key = Curve25519.Signing.PrivateKey()
        let identity = PhoneDeviceIdentity(
            deviceID: UUID(uuidString: "80000000-0000-0000-0000-000000000004")!,
            privateKey: key.rawRepresentation
        )
        let pairing = pairedGuardian(deviceID: identity.deviceID)
        let pending = try PhoneRemoteOperationalCodec().makeObserveRequest(
            identity: identity,
            pairing: pairing,
            expectedGeneration: 0,
            sequence: 1,
            cursor: nil,
            acknowledgedCommandIDs: [],
            requestID: requestID,
            commandID: commandID,
            nonce: nonce,
            now: now,
            deadline: now.addingTimeInterval(10)
        )

        let request = try GuardianRemoteWireCodec().decodeRequest(pending.frame)
        #expect(request.requestID == requestID)
        guard case let .command(packet) = request.body else {
            Issue.record("Expected signed command")
            return
        }
        let device = GuardianRemoteDevice(
            id: identity.deviceID,
            publicKey: key.publicKey.rawRepresentation,
            capabilities: [.observe],
            status: .active,
            pairingEpoch: pairing.pairingEpoch,
            revocationEpoch: pairing.revocationEpoch,
            lastAcceptedSequence: 0,
            pairedAt: pairing.pairedAt,
            lastSeenAt: nil
        )
        #expect(try GuardianRemoteCommandAuthenticator().verify(
            packet.signedCommand,
            device: device
        ) == .authenticated(packet.signedCommand.command))
        #expect(packet.signedCommand.command.action == .observe)
        #expect(packet.signedCommand.command.expectedGeneration == 0)
        #expect(packet.signedCommand.command.sequence == 1)
        #expect(packet.signedCommand.command.targetThreadID == "guardian:inventory")
        #expect(packet.signedCommand.command.payloadDigest == Data(SHA256.hash(data: packet.payload)))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let observe = try decoder.decode(GuardianRemoteObserveRequest.self, from: packet.payload)
        #expect(observe == GuardianRemoteObserveRequest(cursor: nil))
    }

    @Test("command response rejects a different device before returning outcome state")
    func wrongDeviceResponseRejected() throws {
        let pairing = pairedGuardian(deviceID: UUID())
        let digest = Data(repeating: 0x55, count: 32)
        let response = GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: requestID,
            body: .commandOutcome(.init(
                receipt: .init(
                    commandID: commandID,
                    deviceID: UUID(),
                    payloadDigest: digest,
                    generation: 7,
                    sequence: 2,
                    acceptedAt: now
                ),
                state: .pending
            ))
        )
        let frame = try GuardianRemoteWireCodec().encode(response)

        #expect(throws: PhoneRemoteOperationalCodecError.deviceIdentityMismatch) {
            _ = try PhoneRemoteOperationalCodec().decodeCommandResponse(
                frame,
                expectedRequestID: requestID,
                expectedCommandID: commandID,
                expectedDeviceID: pairing.deviceID,
                expectedPayloadDigest: digest
            )
        }
    }

    @Test("Mac observation decodes to an authoritative phone snapshot")
    func observationResponseMatchesMacContract() throws {
        let deviceID = UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
        let digest = Data(repeating: 0x66, count: 32)
        let receipt = GuardianRemoteReceipt(
            commandID: commandID,
            deviceID: deviceID,
            payloadDigest: digest,
            generation: 7,
            sequence: 1,
            acceptedAt: now
        )
        let snapshot = GuardianIPCFullSnapshot(
            protocolVersion: .current,
            generation: 7,
            lastSequence: 12,
            capturedAt: now,
            operations: [],
            tasks: [
                .init(
                    threadID: "thread-1",
                    state: .stuck,
                    reason: .coherentEvidence,
                    serverGeneration: 7,
                    eventSequence: 12,
                    confidence: 0.95,
                    expiresAt: now.addingTimeInterval(10)
                ),
            ],
            taskInventoryCompleteness: .complete
        )
        let response = GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: requestID,
            body: .observation(.init(receipt: receipt, snapshot: snapshot))
        )

        let decoded = try PhoneRemoteOperationalCodec().decodeObserveResponse(
            GuardianRemoteWireCodec().encode(response),
            expectedRequestID: requestID,
            expectedCommandID: commandID,
            expectedDeviceID: deviceID,
            expectedPayloadDigest: digest,
            expectedCursor: ProjectionCursor(generation: 7, sequence: 12)
        )

        #expect(decoded.outcome.state == .applied(at: now))
        #expect(decoded.acknowledgements.isEmpty)
        guard case let .snapshot(phoneSnapshot) = decoded.payload else {
            Issue.record("Expected full snapshot")
            return
        }
        #expect(phoneSnapshot.cursor == ProjectionCursor(generation: 7, sequence: 12))
        #expect(phoneSnapshot.inventoryCompleteness == .complete)
        #expect(phoneSnapshot.tasks == [
            .init(
                threadID: "thread-1",
                state: .stuck,
                reason: "coherentEvidence",
                serverGeneration: 7,
                eventSequence: 12,
                confidence: 0.95,
                expiresAt: now.addingTimeInterval(10)
            ),
        ])
    }

    @Test("Mac event batch requests authoritative snapshot reconciliation")
    func eventBatchResponseMatchesMacContract() throws {
        let deviceID = UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
        let digest = Data(repeating: 0x77, count: 32)
        let receipt = GuardianRemoteReceipt(
            commandID: commandID,
            deviceID: deviceID,
            payloadDigest: digest,
            generation: 7,
            sequence: 1,
            acceptedAt: now
        )
        let nextCursor = GuardianIPCEventCursor(generation: 7, lastSequence: 13)
        let response = GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: requestID,
            body: .eventBatch(.init(
                receipt: receipt,
                events: [
                    .init(
                        generation: 7,
                        sequence: 13,
                        operationID: nil,
                        emittedAt: now,
                        kind: .taskChanged
                    ),
                ],
                nextCursor: nextCursor
            ))
        )

        let decoded = try PhoneRemoteOperationalCodec().decodeObserveResponse(
            GuardianRemoteWireCodec().encode(response),
            expectedRequestID: requestID,
            expectedCommandID: commandID,
            expectedDeviceID: deviceID,
            expectedPayloadDigest: digest,
            expectedCursor: ProjectionCursor(generation: 7, sequence: 12)
        )

        #expect(decoded.outcome.state == .applied(at: now))
        guard case let .eventsRequireSnapshot(phoneCursor) = decoded.payload else {
            Issue.record("Expected authoritative snapshot reconciliation")
            return
        }
        #expect(phoneCursor == ProjectionCursor(generation: 7, sequence: 13))
    }

    @Test("Mac recovery history survives the phone wire projection")
    func operationHistoryMatchesMacContract() throws {
        let deviceID = UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
        let digest = Data(repeating: 0x78, count: 32)
        let operationID = UUID(uuidString: "80000000-0000-0000-0000-000000000006")!
        let receipt = GuardianRemoteReceipt(
            commandID: commandID,
            deviceID: deviceID,
            payloadDigest: digest,
            generation: 7,
            sequence: 1,
            acceptedAt: now
        )
        let history = GuardianIPCOperationHistoryItem(
            operationID: operationID,
            kind: .hardRestart,
            originThreadID: "thread-1",
            phase: .monitoring,
            createdAt: now.addingTimeInterval(-5),
            updatedAt: now
        )
        let snapshot = GuardianIPCFullSnapshot(
            protocolVersion: .current,
            generation: 7,
            lastSequence: 12,
            capturedAt: now,
            operations: [],
            operationHistory: .init(
                items: [history],
                totalCount: 1,
                completeness: .complete
            ),
            tasks: [],
            taskInventoryCompleteness: .complete
        )
        let response = GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: requestID,
            body: .observation(.init(receipt: receipt, snapshot: snapshot))
        )

        let decoded = try PhoneRemoteOperationalCodec().decodeObserveResponse(
            GuardianRemoteWireCodec().encode(response),
            expectedRequestID: requestID,
            expectedCommandID: commandID,
            expectedDeviceID: deviceID,
            expectedPayloadDigest: digest
        )

        guard case let .snapshot(phoneSnapshot) = decoded.payload else {
            Issue.record("Expected full snapshot")
            return
        }
        #expect(phoneSnapshot.operationHistoryIsComplete)
        #expect(phoneSnapshot.operationHistory == [PhoneRemoteOperationSnapshot(
            operationID: operationID,
            kind: .hardRestart,
            originThreadID: "thread-1",
            phase: .monitoring,
            createdAt: now.addingTimeInterval(-5),
            updatedAt: now
        )])
    }

    @Test("Mac command history survives reconnect with exact metadata and outcome")
    func commandHistoryMatchesMacContract() throws {
        let deviceID = UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
        let digest = Data(repeating: 0x79, count: 32)
        let historyCommandID = UUID(uuidString: "80000000-0000-0000-0000-000000000007")!
        let observeReceipt = GuardianRemoteReceipt(
            commandID: commandID,
            deviceID: deviceID,
            payloadDigest: digest,
            generation: 7,
            sequence: 2,
            acceptedAt: now
        )
        let commandReceipt = GuardianRemoteReceipt(
            commandID: historyCommandID,
            deviceID: deviceID,
            payloadDigest: Data(repeating: 0x7a, count: 32),
            generation: 7,
            sequence: 1,
            acceptedAt: now.addingTimeInterval(-2)
        )
        let historyItem = GuardianRemoteCommandHistoryItem(
            action: .prompt,
            targetThreadID: "thread-1",
            expectedGeneration: 7,
            issuedAt: now.addingTimeInterval(-3),
            deadline: now.addingTimeInterval(20),
            outcome: .init(receipt: commandReceipt, state: .pending),
            outcomeVersion: 1,
            updatedAt: now.addingTimeInterval(-2)
        )
        let response = GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: requestID,
            body: .observation(.init(
                receipt: observeReceipt,
                commandHistory: .init(
                    items: [historyItem],
                    totalCount: 1,
                    completeness: .complete
                ),
                snapshot: GuardianIPCFullSnapshot(
                    protocolVersion: .current,
                    generation: 7,
                    lastSequence: 0,
                    capturedAt: now,
                    operations: [],
                    tasks: [],
                    taskInventoryCompleteness: .complete
                )
            ))
        )

        let decoded = try PhoneRemoteOperationalCodec().decodeObserveResponse(
            GuardianRemoteWireCodec().encode(response),
            expectedRequestID: requestID,
            expectedCommandID: commandID,
            expectedDeviceID: deviceID,
            expectedPayloadDigest: digest
        )

        #expect(decoded.commandHistory.completeness == .complete)
        #expect(decoded.commandHistory.totalCount == 1)
        let item = try #require(decoded.commandHistory.items.first)
        #expect(item.action == .prompt)
        #expect(item.targetThreadID == "thread-1")
        #expect(item.expectedGeneration == 7)
        #expect(item.issuedAt == now.addingTimeInterval(-3))
        #expect(item.deadline == now.addingTimeInterval(20))
        #expect(item.outcome.commandID == historyCommandID)
        #expect(item.outcome.state == .accepted)
        #expect(item.outcomeVersion == 1)
        #expect(item.updatedAt == now.addingTimeInterval(-2))
    }

    @Test("legacy observation without command history is explicitly unavailable")
    func legacyObservationWithoutCommandHistoryDecodesAsUnavailable() throws {
        let deviceID = UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
        let digest = Data(repeating: 0x7b, count: 32)
        let response = GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: requestID,
            body: .observation(.init(
                receipt: .init(
                    commandID: commandID,
                    deviceID: deviceID,
                    payloadDigest: digest,
                    generation: 7,
                    sequence: 1,
                    acceptedAt: now
                ),
                snapshot: GuardianIPCFullSnapshot(
                    protocolVersion: .current,
                    generation: 7,
                    lastSequence: 0,
                    capturedAt: now,
                    operations: [],
                    tasks: [],
                    taskInventoryCompleteness: .complete
                )
            ))
        )

        let decoded = try PhoneRemoteOperationalCodec().decodeObserveResponse(
            GuardianRemoteWireCodec().encode(response),
            expectedRequestID: requestID,
            expectedCommandID: commandID,
            expectedDeviceID: deviceID,
            expectedPayloadDigest: digest
        )

        #expect(decoded.commandHistory.completeness == .unavailable)
        #expect(decoded.commandHistory.items.isEmpty)
        #expect(decoded.commandHistory.totalCount == 0)
    }

    @Test("command history rejects another device and inconsistent generation metadata")
    func commandHistoryRejectsCrossDeviceAndMetadataMismatch() throws {
        let deviceID = UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
        let digest = Data(repeating: 0x7c, count: 32)
        let observeReceipt = GuardianRemoteReceipt(
            commandID: commandID,
            deviceID: deviceID,
            payloadDigest: digest,
            generation: 7,
            sequence: 2,
            acceptedAt: now
        )
        for item in [
            GuardianRemoteCommandHistoryItem(
                action: .prompt,
                targetThreadID: "thread-1",
                expectedGeneration: 7,
                issuedAt: now.addingTimeInterval(-3),
                deadline: now.addingTimeInterval(20),
                outcome: .init(
                    receipt: .init(
                        commandID: UUID(),
                        deviceID: UUID(),
                        payloadDigest: Data(repeating: 0x7d, count: 32),
                        generation: 7,
                        sequence: 1,
                        acceptedAt: now.addingTimeInterval(-2)
                    ),
                    state: .pending
                ),
                outcomeVersion: 1,
                updatedAt: now.addingTimeInterval(-2)
            ),
            GuardianRemoteCommandHistoryItem(
                action: .prompt,
                targetThreadID: "thread-1",
                expectedGeneration: 8,
                issuedAt: now.addingTimeInterval(-3),
                deadline: now.addingTimeInterval(20),
                outcome: .init(
                    receipt: .init(
                        commandID: UUID(),
                        deviceID: deviceID,
                        payloadDigest: Data(repeating: 0x7e, count: 32),
                        generation: 7,
                        sequence: 1,
                        acceptedAt: now.addingTimeInterval(-2)
                    ),
                    state: .pending
                ),
                outcomeVersion: 1,
                updatedAt: now.addingTimeInterval(-2)
            ),
        ] {
            let response = GuardianRemoteWireResponse(
                protocolVersion: .current,
                requestID: requestID,
                body: .observation(.init(
                    receipt: observeReceipt,
                    commandHistory: .init(
                        items: [item],
                        totalCount: 1,
                        completeness: .complete
                    ),
                    snapshot: GuardianIPCFullSnapshot(
                        protocolVersion: .current,
                        generation: 7,
                        lastSequence: 0,
                        capturedAt: now,
                        operations: [],
                        tasks: [],
                        taskInventoryCompleteness: .complete
                    )
                ))
            )
            #expect(throws: PhoneRemoteOperationalCodecError.invalidResponse) {
                _ = try PhoneRemoteOperationalCodec().decodeObserveResponse(
                    GuardianRemoteWireCodec().encode(response),
                    expectedRequestID: requestID,
                    expectedCommandID: commandID,
                    expectedDeviceID: deviceID,
                    expectedPayloadDigest: digest
                )
            }
        }
    }

    private func pairedGuardian(deviceID: UUID) -> PhonePairedGuardian {
        PhonePairedGuardian(
            guardianID: UUID(uuidString: "80000000-0000-0000-0000-000000000005")!,
            guardianPublicKey: Data(repeating: 0x11, count: 32),
            deviceID: deviceID,
            endpoint: .init(
                host: "192.168.1.20",
                port: 47_411,
                tlsCertificateHash: Data(repeating: 0x22, count: 32)
            ),
            capabilities: [.observe, .promptAgent, .restartAgent, .cancelRecovery],
            pairingEpoch: 1,
            revocationEpoch: 0,
            pairedAt: now.addingTimeInterval(-100)
        )
    }
}
