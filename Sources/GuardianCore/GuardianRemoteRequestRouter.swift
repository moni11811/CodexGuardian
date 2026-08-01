import Foundation

public struct GuardianRemoteObservation: Codable, Equatable, Sendable {
    public let receipt: GuardianRemoteReceipt
    public let acknowledgements: [GuardianRemoteOutcomeAcknowledgement]
    public let commandHistory: GuardianRemoteCommandHistoryPage?
    public let snapshot: GuardianIPCFullSnapshot

    public init(
        receipt: GuardianRemoteReceipt,
        acknowledgements: [GuardianRemoteOutcomeAcknowledgement] = [],
        commandHistory: GuardianRemoteCommandHistoryPage? = nil,
        snapshot: GuardianIPCFullSnapshot
    ) {
        self.receipt = receipt
        self.acknowledgements = acknowledgements
        self.commandHistory = commandHistory
        self.snapshot = snapshot
    }
}

public actor GuardianRemoteRequestRouter {
    public typealias SnapshotProvider = @Sendable () async throws -> GuardianIPCFullSnapshot
    public typealias EventReplayProvider = @Sendable (
        GuardianIPCEventCursor,
        Int
    ) async throws -> GuardianDaemonEventReplay
    public typealias PairingHandler = @Sendable (
        GuardianRemotePairingRequest,
        Date
    ) async throws -> GuardianRemotePairingReceipt

    private let gateway: GuardianRemoteGatewayCore
    private let snapshotProvider: SnapshotProvider
    private let eventReplayProvider: EventReplayProvider?
    private let pairingHandler: PairingHandler?

    public init(
        gateway: GuardianRemoteGatewayCore,
        snapshotProvider: @escaping SnapshotProvider,
        eventReplayProvider: EventReplayProvider? = nil,
        pairingHandler: PairingHandler? = nil
    ) {
        self.gateway = gateway
        self.snapshotProvider = snapshotProvider
        self.eventReplayProvider = eventReplayProvider
        self.pairingHandler = pairingHandler
    }

    public func handle(
        _ request: GuardianRemoteWireRequest,
        currentGeneration: Int64,
        now: Date = Date()
    ) async throws -> GuardianRemoteWireResponse {
        guard request.protocolVersion == .current,
              currentGeneration > 0 else {
            return response(to: request, body: .rejected(.invalidRequest))
        }
        switch request.body {
        case let .pairing(pairing):
            guard let pairingHandler else {
                return response(to: request, body: .rejected(.serverUnavailable))
            }
            do {
                return response(
                    to: request,
                    body: .paired(try await pairingHandler(pairing, now))
                )
            } catch {
                return response(to: request, body: .rejected(.unauthorized))
            }
        case let .command(packet):
            let gatewayResponse = try await gateway.handle(
                packet,
                currentGeneration: currentGeneration,
                now: now
            )
            guard packet.signedCommand.command.action == .observe,
                  let receipt = Self.receipt(from: gatewayResponse) else {
                if let receipt = Self.receipt(from: gatewayResponse) {
                    guard let outcome = try await gateway.commandOutcome(
                        commandID: receipt.commandID
                    ) else {
                        return response(to: request, body: .rejected(.serverUnavailable))
                    }
                    return response(to: request, body: .commandOutcome(outcome))
                }
                return response(to: request, body: .gateway(gatewayResponse))
            }
            let observeRequest = Self.observeRequest(from: packet.payload)
                ?? GuardianRemoteObserveRequest(cursor: nil)
            let acknowledgements: [GuardianRemoteOutcomeAcknowledgement]
            do {
                acknowledgements = try await gateway.acknowledgeOutcomes(
                    deviceID: packet.signedCommand.command.deviceID,
                    commandIDs: observeRequest.acknowledgedCommandIDs,
                    at: now
                )
            } catch {
                return response(to: request, body: .rejected(.invalidRequest))
            }
            let commandHistory: GuardianRemoteCommandHistoryPage
            do {
                commandHistory = try await gateway.commandHistory(
                    deviceID: packet.signedCommand.command.deviceID
                )
            } catch {
                return response(to: request, body: .rejected(.serverUnavailable))
            }
            if let cursor = observeRequest.cursor,
               let eventReplayProvider,
               let replay = try? await eventReplayProvider(
                   cursor,
                   observeRequest.maximumEvents
               ),
               case let .events(events, nextCursor) = replay,
               Self.replayIsValid(
                   events,
                   nextCursor: nextCursor,
                   after: cursor,
                   currentGeneration: currentGeneration,
                   maximumEvents: observeRequest.maximumEvents
               ) {
                return response(
                    to: request,
                    body: .eventBatch(.init(
                        receipt: receipt,
                        acknowledgements: acknowledgements,
                        commandHistory: commandHistory,
                        events: events,
                        nextCursor: nextCursor
                    ))
                )
            }
            let snapshot: GuardianIPCFullSnapshot
            do {
                snapshot = try await snapshotProvider()
            } catch {
                return response(to: request, body: .rejected(.serverUnavailable))
            }
            guard snapshot.generation == currentGeneration else {
                return response(to: request, body: .rejected(.snapshotRequired))
            }
            return response(
                to: request,
                body: .observation(.init(
                    receipt: receipt,
                    acknowledgements: acknowledgements,
                    commandHistory: commandHistory,
                    snapshot: snapshot
                ))
            )
        case .snapshot:
            return response(to: request, body: .rejected(.unauthorized))
        case let .ping(nonce):
            return response(to: request, body: .pong(nonce))
        }
    }

    private func response(
        to request: GuardianRemoteWireRequest,
        body: GuardianRemoteWireResponseBody
    ) -> GuardianRemoteWireResponse {
        GuardianRemoteWireResponse(
            protocolVersion: .current,
            requestID: request.requestID,
            body: body
        )
    }

    private static func receipt(
        from response: GuardianRemoteGatewayResponse
    ) -> GuardianRemoteReceipt? {
        guard case let .reconciled(reconciliation) = response else { return nil }
        switch reconciliation {
        case let .accepted(receipt), let .duplicate(receipt):
            return receipt
        case .rejected, .snapshotRequired:
            return nil
        }
    }

    private static func observeRequest(
        from payload: Data
    ) -> GuardianRemoteObserveRequest? {
        if payload.isEmpty {
            return GuardianRemoteObserveRequest(cursor: nil)
        }
        guard let request = try? JSONDecoder().decode(
            GuardianRemoteObserveRequest.self,
            from: payload
        ), request.isValid else {
            return nil
        }
        return request
    }

    private static func replayIsValid(
        _ events: [GuardianIPCEvent],
        nextCursor: GuardianIPCEventCursor,
        after cursor: GuardianIPCEventCursor,
        currentGeneration: Int64,
        maximumEvents: Int
    ) -> Bool {
        guard cursor.generation == currentGeneration,
              nextCursor.generation == currentGeneration,
              events.count <= maximumEvents else {
            return false
        }
        var expectedSequence = cursor.lastSequence + 1
        for event in events {
            guard event.generation == currentGeneration,
                  event.sequence == expectedSequence,
                  event.emittedAt.timeIntervalSince1970.isFinite,
                  (event.kind == .operationChanged) == (event.operationID != nil) else {
                return false
            }
            expectedSequence += 1
        }
        return nextCursor.lastSequence == (events.last?.sequence ?? cursor.lastSequence)
    }
}
