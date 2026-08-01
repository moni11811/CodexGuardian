import Foundation
import GuardianPhoneCore

enum GuardianPhoneServiceError: LocalizedError {
    case transportUnavailable
    case invalidPairingCode

    var errorDescription: String? {
        switch self {
        case .transportUnavailable: "Production transport is not available yet."
        case .invalidPairingCode: "That pairing code is not valid."
        }
    }
}

protocol GuardianPhoneService: Sendable {
    func loadSnapshot() async throws -> GuardianPhoneSnapshot
    func pair(code: String) async throws
    func sendPrompt(_ prompt: String, to target: PhoneCommandTarget) async throws
    func fetchRestartImpact(for target: PhoneCommandTarget) async throws -> ImpactSnapshot
    func restartAgent(using snapshot: ImpactSnapshot) async throws
}

struct ProductionGuardianPhoneService: GuardianPhoneService {
    typealias PairingAction = @Sendable (String) async throws -> Void
    typealias ObserveAction = @Sendable () async throws -> PhoneRemoteSnapshot

    private let pairing: PairingAction
    private let observe: ObserveAction

    init() {
        let client = PhoneRemoteClient.production()
        pairing = Self.performPairing
        observe = { try await client.observe() }
    }

    init(pairing: @escaping PairingAction) {
        self.pairing = pairing
        observe = { throw GuardianPhoneServiceError.transportUnavailable }
    }

    init(
        pairing: @escaping PairingAction,
        observe: @escaping ObserveAction
    ) {
        self.pairing = pairing
        self.observe = observe
    }

    func loadSnapshot() async throws -> GuardianPhoneSnapshot {
        GuardianPhoneProjectionMapper().map(try await observe())
    }
    func pair(code: String) async throws {
        try await pairing(code)
    }
    func sendPrompt(_ prompt: String, to target: PhoneCommandTarget) async throws {
        throw GuardianPhoneServiceError.transportUnavailable
    }
    func fetchRestartImpact(for target: PhoneCommandTarget) async throws -> ImpactSnapshot {
        throw GuardianPhoneServiceError.transportUnavailable
    }
    func restartAgent(using snapshot: ImpactSnapshot) async throws {
        throw GuardianPhoneServiceError.transportUnavailable
    }

    private static func performPairing(_ code: String) async throws {
        let invitation: PhonePairingInvitation
        do {
            invitation = try PhonePairingCodeDecoder().decode(code)
        } catch {
            throw GuardianPhoneServiceError.invalidPairingCode
        }
        let supportedActions: Set<PhoneAction> = [
            .observe,
            .promptAgent,
            .restartAgent,
        ]
        let requestedActions = invitation.allowedCapabilities.intersection(supportedActions)
        guard requestedActions.contains(.observe) else {
            throw GuardianPhoneServiceError.invalidPairingCode
        }
        let transport = PhonePinnedTLSExchange()
        let coordinator = PhonePairingCoordinator(
            storage: PhoneKeychainPairingStorage(),
            exchange: { endpoint, frame in
                try await transport(endpoint: endpoint, requestFrame: frame)
            }
        )
        _ = try await coordinator.pair(
            code: code,
            requestedActions: requestedActions
        )
    }
}

struct PreviewGuardianPhoneService: GuardianPhoneService {
    let snapshot: GuardianPhoneSnapshot

    func loadSnapshot() async throws -> GuardianPhoneSnapshot { snapshot }
    func pair(code: String) async throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GuardianPhoneServiceError.invalidPairingCode
        }
    }
    func sendPrompt(_ prompt: String, to target: PhoneCommandTarget) async throws {
        guard target.isValid else { throw GuardianPhoneServiceError.transportUnavailable }
    }
    func fetchRestartImpact(for target: PhoneCommandTarget) async throws -> ImpactSnapshot {
        guard target.isValid else { throw GuardianPhoneServiceError.transportUnavailable }
        return ImpactSnapshot(
            targetThreadID: target.threadID,
            serverGeneration: target.serverGeneration,
            capturedAt: .now,
            completeness: .complete,
            impact: .known(activeTaskCount: 0, uncommittedWorkspaceCount: 0)
        )
    }
    func restartAgent(using snapshot: ImpactSnapshot) async throws {}
}

extension GuardianPhoneSnapshot {
    static let preview = GuardianPhoneSnapshot(
        tasks: [
            GuardianTaskItem(
                id: "stuck-build",
                title: "Fix recovery loop",
                project: "Codex Guardian",
                summary: "Tool stalled after preparing a restart. Waiting for a safe decision.",
                activity: .needsAttention,
                updatedAt: .now,
                command: PhoneCommandRecord(
                    id: OperationID("preview-pending"),
                    action: .repair,
                    state: .pending,
                    createdAt: .now
                )
            ),
            GuardianTaskItem(
                id: "tests",
                title: "Run regression tests",
                project: "Codex Guardian",
                summary: "Crash replay verification is still running.",
                activity: .active,
                updatedAt: .now.addingTimeInterval(-90),
                command: nil
            ),
            GuardianTaskItem(
                id: "docs",
                title: "Update simple README",
                project: "Codex Guardian",
                summary: "Documentation completed safely.",
                activity: .recent,
                updatedAt: .now.addingTimeInterval(-1_800),
                command: PhoneCommandRecord(
                    id: OperationID("preview-applied"),
                    action: .observe,
                    state: .applied(at: .now.addingTimeInterval(-1_800)),
                    createdAt: .now.addingTimeInterval(-1_900)
                )
            ),
        ],
        capabilities: [
            PhoneCapability(action: .observe, availability: .available),
            PhoneCapability(action: .promptAgent, availability: .available),
            PhoneCapability(action: .restartAgent, availability: .available),
            PhoneCapability(action: .approve, availability: .adapterUnavailable),
        ],
        computerName: "Studio Mac",
        serverGeneration: 7,
        operationHistory: [
            GuardianOperationItem(
                id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
                kind: .hardRestart,
                threadID: "stuck-build",
                phase: .acknowledged,
                createdAt: .now.addingTimeInterval(-2_000),
                updatedAt: .now.addingTimeInterval(-1_800)
            ),
        ],
        operationHistoryCompleteness: .complete
    )
}
