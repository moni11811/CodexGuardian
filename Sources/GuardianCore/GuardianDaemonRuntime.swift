import CryptoKit
import Foundation

public struct GuardianLocalClientRegistration: Sendable {
    public let credential: Data
    public let client: GuardianIPCAuthenticatedClient
    public let peerPolicy: GuardianLocalPeerPolicy?

    public init(
        credential: Data,
        client: GuardianIPCAuthenticatedClient,
        peerPolicy: GuardianLocalPeerPolicy? = nil
    ) {
        self.credential = credential
        self.client = client
        self.peerPolicy = peerPolicy
    }
}

public enum GuardianDaemonMode: String, Codable, Equatable, Sendable {
    case shadowOnly
    case authoritative
}

public enum GuardianDaemonRuntimeError: Error, Equatable, Sendable {
    case invalidCredential
    case duplicateCredential
    case duplicateClientID
    case invalidPeerPolicy
    case authorityNotGranted
}

public struct GuardianDaemonRequest: Codable, Equatable, Sendable {
    public let credential: Data
    public let command: GuardianIPCCommand

    public init(credential: Data, command: GuardianIPCCommand) {
        self.credential = credential
        self.command = command
    }
}

public enum GuardianDaemonRejection: Codable, Equatable, Sendable {
    case unauthorizedClient
    case invalidCommand(GuardianIPCCommandRejection)
    case shadowMode
    case authorityFenceDenied
    case unsupportedAuthoritativeAction
    case storageUnavailable
}

public enum GuardianDaemonReply: Codable, Equatable, Sendable {
    case snapshot(GuardianIPCFullSnapshot)
    case accepted(operationID: UUID)
    case rejected(GuardianDaemonRejection)
}

public actor GuardianDaemonRuntime {
    public let generation: Int64
    private let journal: GuardianJournal
    private let mode: GuardianDaemonMode
    private let authorityPermit: GuardianAuthorityPermit?
    private let clientsByCredentialHash: [Data: GuardianLocalClientRegistration]
    private let validator = GuardianIPCCommandValidator()

    private init(
        journal: GuardianJournal,
        generation: Int64,
        clientsByCredentialHash: [Data: GuardianLocalClientRegistration],
        mode: GuardianDaemonMode,
        authorityPermit: GuardianAuthorityPermit?
    ) {
        self.journal = journal
        self.generation = generation
        self.mode = mode
        self.authorityPermit = authorityPermit
        self.clientsByCredentialHash = clientsByCredentialHash
    }

    public static func start(
        journal: GuardianJournal,
        registeredClients: [GuardianLocalClientRegistration],
        mode: GuardianDaemonMode,
        at date: Date = Date()
    ) throws -> GuardianDaemonRuntime {
        var clientsByCredentialHash: [Data: GuardianLocalClientRegistration] = [:]
        var clientIDs: Set<UUID> = []
        for registration in registeredClients {
            guard registration.credential.count == 32 else {
                throw GuardianDaemonRuntimeError.invalidCredential
            }
            let credentialHash = Self.hash(registration.credential)
            guard clientsByCredentialHash[credentialHash] == nil else {
                throw GuardianDaemonRuntimeError.duplicateCredential
            }
            guard clientIDs.insert(registration.client.clientID).inserted else {
                throw GuardianDaemonRuntimeError.duplicateClientID
            }
            if let peerPolicy = registration.peerPolicy {
                guard peerPolicy.isValid,
                      peerPolicy.role == registration.client.role else {
                    throw GuardianDaemonRuntimeError.invalidPeerPolicy
                }
            } else if mode == .authoritative {
                throw GuardianDaemonRuntimeError.invalidPeerPolicy
            }
            clientsByCredentialHash[credentialHash] = registration
        }
        let authorityPermit: GuardianAuthorityPermit?
        switch mode {
        case .shadowOnly:
            authorityPermit = nil
        case .authoritative:
            do {
                authorityPermit = try journal.issueAuthorityPermit(owner: .daemon, at: date)
            } catch {
                throw GuardianDaemonRuntimeError.authorityNotGranted
            }
        }
        let state = try journal.beginDaemonGeneration(at: date)
        return GuardianDaemonRuntime(
            journal: journal,
            generation: state.generation,
            clientsByCredentialHash: clientsByCredentialHash,
            mode: mode,
            authorityPermit: authorityPermit
        )
    }

    public func handle(
        _ request: GuardianDaemonRequest,
        verifiedPeer: GuardianVerifiedLocalPeer? = nil,
        now: Date = Date()
    ) -> GuardianDaemonReply {
        guard let registration = clientsByCredentialHash[Self.hash(request.credential)] else {
            return .rejected(.unauthorizedClient)
        }
        if let peerPolicy = registration.peerPolicy {
            guard let verifiedPeer,
                  peerPolicy.accepts(verifiedPeer) else {
                return .rejected(.unauthorizedClient)
            }
        }
        let client = registration.client
        switch validator.validate(
            request.command,
            from: client,
            currentGeneration: generation,
            now: now
        ) {
        case let .failure(reason):
            return .rejected(.invalidCommand(reason))
        case .success:
            break
        }

        if request.command.action == .observe {
            do {
                return .snapshot(try currentSnapshot(now: now))
            } catch {
                return .rejected(.storageUnavailable)
            }
        }
        guard mode == .authoritative else {
            return .rejected(.shadowMode)
        }
        guard let authorityPermit else {
            return .rejected(.authorityFenceDenied)
        }
        do {
            try journal.validateAuthorityPermit(authorityPermit, at: now)
        } catch {
            return .rejected(.authorityFenceDenied)
        }
        return .rejected(.unsupportedAuthoritativeAction)
    }

    public func currentSnapshot(now: Date = Date()) throws -> GuardianIPCFullSnapshot {
        guard now.timeIntervalSince1970.isFinite,
              let state = try journal.daemonState(),
              state.generation == generation else {
            throw GuardianJournalError.storageUnavailable
        }
        let storedOperations = try journal.operations()
        let operations = try storedOperations.map {
            let manifest = try journal.readinessManifest(operationID: $0.id)
            return GuardianIPCOperationSnapshot(
                operationID: $0.id,
                originThreadID: $0.originThreadID,
                phase: $0.phase.rawValue,
                readiness: manifest.isEmpty
                    ? nil
                    : GuardianReadinessPolicy().decision(records: manifest, now: now)
            )
        }
        let allOperationHistory = storedOperations.map {
            GuardianIPCOperationHistoryItem(
                operationID: $0.id,
                kind: $0.kind,
                originThreadID: $0.originThreadID,
                phase: $0.phase,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        let operationHistory = GuardianIPCOperationHistoryPage(
            items: Array(allOperationHistory.suffix(
                GuardianIPCOperationHistoryPage.maximumItems
            )),
            totalCount: allOperationHistory.count,
            completeness: allOperationHistory.count
                <= GuardianIPCOperationHistoryPage.maximumItems ? .complete : .truncated
        )
        let storedTasks = try journal.taskSnapshots()
        let projectionCheckpoint = try journal.taskProjectionCheckpoint()
        let tasks = storedTasks.map {
            GuardianIPCTaskSnapshot(
                threadID: $0.threadID,
                state: $0.state,
                reason: $0.state == .unknown ? .noEvidence : .coherentEvidence,
                serverGeneration: $0.serverGeneration,
                eventSequence: $0.eventSequence,
                confidence: $0.confidence,
                expiresAt: $0.expiresAt
            )
        }
        let checkpointIsCurrent = projectionCheckpoint.map { checkpoint in
            checkpoint.inventoryCompleteness == .complete
                && checkpoint.expiresAt > now
                && storedTasks.allSatisfy {
                    $0.serverGeneration == checkpoint.serverGeneration
                        && $0.eventSequence == checkpoint.eventSequence
                }
        } ?? false
        let legacyNonemptyProjectionIsComplete = projectionCheckpoint == nil
            && !storedTasks.isEmpty
            && storedTasks.allSatisfy { $0.inventoryCompleteness == .complete }
        let taskInventoryCompleteness: TaskInventoryCompleteness =
            checkpointIsCurrent || legacyNonemptyProjectionIsComplete ? .complete : .incomplete
        return GuardianIPCFullSnapshot(
            protocolVersion: .current,
            generation: generation,
            lastSequence: state.lastSequence,
            capturedAt: now,
            operations: operations,
            operationHistory: operationHistory,
            tasks: tasks,
            taskInventoryCompleteness: taskInventoryCompleteness
        )
    }

    private static func hash(_ credential: Data) -> Data {
        Data(SHA256.hash(data: credential))
    }
}
