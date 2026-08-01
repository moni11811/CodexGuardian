import Foundation
import GuardianPhoneCore
import Observation

@MainActor
@Observable
final class GuardianPhoneStore {
    typealias ReconnectSleep = @Sendable (TimeInterval) async throws -> Void

    private let service: any GuardianPhoneService
    private let reconnectSleep: ReconnectSleep
    private let restartPolicy = DestructiveActionPolicy(maximumSnapshotAge: 30)
    private let reconnectFailureClassifier = PhoneReconnectFailureClassifier()

    private enum RefreshResult {
        case connected
        case retry
        case stop
    }

    var connection: GuardianConnectionState = .loading
    var selectedSegment: GuardianSegment = .attention
    var presentedSheet: GuardianSheet?
    var tasks: [GuardianTaskItem] = []
    var operationHistory: [GuardianOperationItem] = []
    var operationHistoryCompleteness: PhoneRemoteOperationHistoryCompleteness = .unavailable
    var operationHistoryTotalCount = 0
    var commandHistory: [GuardianCommandHistoryItem] = []
    var commandHistoryCompleteness: PhoneRemoteCommandHistoryCompleteness = .unavailable
    var commandHistoryTotalCount = 0

    var operationHistoryIsComplete: Bool {
        operationHistoryCompleteness == .complete
    }
    var capabilities: [PhoneCapability] = []
    var computerName = "Mac"
    var serverGeneration: Int64 = 0
    var selectedTaskID: String?
    var prompt = ""
    var operationError: String?
    var isWorking = false

    init(
        service: any GuardianPhoneService,
        reconnectSleep: @escaping ReconnectSleep = { delay in
            try await ContinuousClock().sleep(for: .seconds(delay))
        }
    ) {
        self.service = service
        self.reconnectSleep = reconnectSleep
    }

    var visibleTasks: [GuardianTaskItem] {
        switch selectedSegment {
        case .attention: tasks.filter { $0.activity == .needsAttention }
        case .active: tasks.filter { $0.activity == .active }
        case .recent: tasks
        }
    }

    var selectedTask: GuardianTaskItem? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    var selectedTarget: PhoneCommandTarget? {
        guard let selectedTaskID else { return nil }
        let target = PhoneCommandTarget(
            threadID: selectedTaskID,
            serverGeneration: serverGeneration
        )
        return target.isValid ? target : nil
    }

    func can(_ action: PhoneAction) -> Bool {
        guard capabilities.first(where: { $0.action == action })?.isActionable == true else {
            return false
        }
        return action == .observe || selectedTarget != nil
    }

    func select(_ task: GuardianTaskItem) {
        selectedTaskID = task.id
        presentedSheet = .task(task)
    }

    func load() async {
        _ = await refresh(showLoading: true)
    }

    func monitor(maximumAttempts: Int? = nil) async {
        guard maximumAttempts.map({ $0 > 0 }) ?? true else { return }
        var backoff = PhoneReconnectBackoff.standard
        var attempts = 0
        while !Task.isCancelled {
            let result = await refresh(showLoading: attempts == 0 && tasks.isEmpty)
            attempts += 1
            if result == .stop { return }
            if let maximumAttempts, attempts >= maximumAttempts { return }
            let delay: TimeInterval
            switch result {
            case .connected:
                delay = backoff.delayAfterSuccess()
            case .retry:
                delay = backoff.delayAfterFailure()
            case .stop:
                return
            }
            do {
                try await reconnectSleep(delay)
            } catch is CancellationError {
                return
            } catch {
                connection = .failed(error.localizedDescription)
                return
            }
        }
    }

    private func refresh(showLoading: Bool) async -> RefreshResult {
        if showLoading { connection = .loading }
        do {
            let snapshot = try await service.loadSnapshot()
            guard !Task.isCancelled else { return .stop }
            tasks = snapshot.tasks
            operationHistory = snapshot.operationHistory
            operationHistoryCompleteness = snapshot.operationHistoryCompleteness
            operationHistoryTotalCount = snapshot.operationHistoryTotalCount
            commandHistory = snapshot.commandHistory
            commandHistoryCompleteness = snapshot.commandHistoryCompleteness
            commandHistoryTotalCount = snapshot.commandHistoryTotalCount
            capabilities = snapshot.capabilities
            computerName = snapshot.computerName
            serverGeneration = snapshot.serverGeneration
            if let selectedTaskID, !tasks.contains(where: { $0.id == selectedTaskID }) {
                self.selectedTaskID = nil
            }
            connection = .ready
            return .connected
        } catch is CancellationError {
            return .stop
        } catch GuardianPhoneServiceError.transportUnavailable {
            connection = .disconnected
            return .stop
        } catch {
            switch reconnectFailureClassifier.disposition(for: error) {
            case .retry:
                connection = .disconnected
                return .retry
            case .requiresPairing:
                connection = .disconnected
                return .stop
            case .stop:
                connection = .failed(error.localizedDescription)
                return .stop
            }
        }
    }

    func pair(code: String) async -> Bool {
        await perform { try await service.pair(code: code) }
    }

    func sendPrompt() async {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard can(.promptAgent), !value.isEmpty, let target = selectedTarget else { return }
        if await perform({ try await service.sendPrompt(value, to: target) }) { prompt = "" }
    }

    func prepareRestart() async {
        guard can(.restartAgent), let target = selectedTarget else {
            operationError = "Select the exact task before requesting recovery."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let snapshot = try await service.fetchRestartImpact(for: target)
            guard restartPolicy.authorization(
                for: .restartAgent,
                targetThreadID: target.threadID,
                expectedGeneration: target.serverGeneration,
                snapshot: snapshot,
                now: .now
            ) == .allowed else {
                operationError = "Restart blocked: impact check is incomplete, stale, or unsafe."
                return
            }
            presentedSheet = .restart(snapshot)
        } catch {
            operationError = error.localizedDescription
        }
    }

    func confirmRestart(using snapshot: ImpactSnapshot) async -> Bool {
        guard let target = selectedTarget,
              restartPolicy.authorization(
                for: .restartAgent,
                targetThreadID: target.threadID,
                expectedGeneration: target.serverGeneration,
                snapshot: snapshot,
                now: .now
              ) == .allowed else {
            operationError = "Restart blocked: refresh the impact check."
            return false
        }
        return await perform { try await service.restartAgent(using: snapshot) }
    }

    private func perform(_ operation: () async throws -> Void) async -> Bool {
        isWorking = true
        operationError = nil
        defer { isWorking = false }
        do {
            try await operation()
            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }
}
