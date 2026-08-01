import AppKit
import Combine
import Darwin
import Foundation
import GuardianClient
import GuardianCore

private enum NativeRecoveryAppError: Error {
    case automaticRestartRequiresAuthoritativeInventory
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status = "Watching for MCP requests"
    @Published private(set) var daemonStatus = "Daemon: checking"
    @Published private(set) var daemonTasks: [GuardianIPCTaskSnapshot] = []
    @Published private(set) var daemonOperations: [GuardianIPCOperationSnapshot] = []
    @Published private(set) var daemonOperationHistory: [GuardianIPCOperationHistoryItem] = []
    @Published private(set) var daemonOperationHistoryCompleteness: GuardianIPCOperationHistoryCompleteness?
    @Published private(set) var daemonOperationHistoryTotalCount = 0

    var daemonOperationHistoryIsComplete: Bool {
        daemonOperationHistoryCompleteness == .complete
    }
    @Published private(set) var daemonSnapshotCapturedAt: Date?
    @Published private(set) var taskInventoryCompleteness: TaskInventoryCompleteness = .incomplete
    @Published var forceRestartConfirmationRequested = false

    private let store = RestartRequestStore()
    private let activityScanner = CodexTaskActivityScanner()
    private let quiescencePolicy = RestartQuiescencePolicy()
    private let automationVerifier = CodexRecoveryAutomationVerifier()
    private let hardRestartGate = HardRestartGate()
    private let recoveryDispatchPolicy = GuardianRecoveryDispatchPolicy()
    private let legacyAuthorityLeaseOwnerID = UUID()
    private lazy var authorityJournal: GuardianJournal? = {
        return try? GuardianJournal(
            databaseURL: store.directory.appending(path: "guardian.sqlite")
        )
    }()
    private lazy var nativeRecoveryOutbox: GuardianProtectedOutbox? = {
        guard let authorityJournal else { return nil }
        return GuardianProtectedOutbox(journal: authorityJournal)
    }()
    private var timer: Timer?
    private var recoveryInProgress = false
    private var automaticRecoveryBlocked = false
    private var daemonProbeInProgress = false
    private var lastDaemonProbeAt = Date.distantPast

    init() {
        try? store.recoverClaims()
        if let blocked = try? store.quarantineUnarmedPendingRequests(), !blocked.isEmpty {
            status = "Preserved \(blocked.count) legacy restart request(s)"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
                self?.refreshDaemonStatusIfNeeded()
            }
        }
        refreshDaemonStatusIfNeeded()
    }

    func requestManualRecovery() {
        guard !recoveryInProgress else { return }
        do {
            let requests = try store.peekAllPending()
            guard let authorityFence = currentAuthorityFence() else {
                status = "Force restart blocked: authority unavailable"
                return
            }
            let decision = GuardianManualRestartPolicy().decision(
                requests: requests,
                verifiedAutomationIDs: verifiedAutomationIDs(for: requests),
                authorityFence: authorityFence
            )
            guard decision == .allowed else {
                switch decision {
                case .blocked(.authorityTransferred):
                    status = "Force restart forwarded to daemon"
                case .blocked(.authorityUnprovable):
                    status = "Force restart blocked: authority unavailable"
                default:
                    status = requests.isEmpty
                        ? "Force restart blocked: no armed recovery"
                        : "Force restart blocked: continuation not verified"
                }
                return
            }
            automaticRecoveryBlocked = false
            recoveryInProgress = true
            status = "Preparing armed recovery"
            Task { @MainActor [weak self] in
                guard let self else { return }
                let prepared = await prepareRecoveryPrompts(for: requests)
                do {
                    let current = try store.peekAllPending()
                    guard Set(current.map(\.id)) == Set(requests.map(\.id)) else {
                        status = "Force restart blocked: recovery request changed"
                        recoveryInProgress = false
                        return
                    }
                    let ids = Set(requests.map(\.id))
                    try store.claimPending(ids: ids)
                    try store.updateClaimedRequests(prepared)
                    restartCodex(
                        using: prepared,
                        claimedRequestIDs: ids,
                        bypassQuietGate: true
                    )
                } catch {
                    try? store.recoverClaims()
                    status = "Force restart blocked: cannot arm continuation"
                    recoveryInProgress = false
                }
            }
        } catch {
            status = "Force restart blocked: request state unavailable"
        }
    }

    func requestForceRestartConfirmation() {
        forceRestartConfirmationRequested = true
    }

    func refreshNow() {
        lastDaemonProbeAt = .distantPast
        refreshDaemonStatusIfNeeded()
    }

    func tasks(in section: GuardianOperatorSection) -> [GuardianIPCTaskSnapshot] {
        let policy = GuardianOperatorPolicy(maximumSnapshotAge: 10)
        return daemonTasks
            .filter { policy.section(for: $0.state) == section }
            .sorted { $0.threadID < $1.threadID }
    }

    var readinessNotice: GuardianOperatorReadinessNotice? {
        GuardianOperatorPolicy(maximumSnapshotAge: 10).readinessNotice(
            operations: daemonOperations
        )
    }

    private func refreshDaemonStatusIfNeeded() {
        guard !daemonProbeInProgress,
              Date().timeIntervalSince(lastDaemonProbeAt) >= 2 else { return }
        daemonProbeInProgress = true
        lastDaemonProbeAt = Date()
        Task { @MainActor [weak self] in
            await self?.probeDaemon()
        }
    }

    private func probeDaemon() async {
        defer { daemonProbeInProgress = false }
        do {
            let stateDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appending(path: "CodexGuardian", directoryHint: .isDirectory)
            let credential = try GuardianCredentialFile.load(
                at: stateDirectory.appending(path: "credentials/mac-ui.token")
            )
            let client = GuardianClient(
                clientID: GuardianLocalClientDefaults.macUIID,
                credential: credential,
                transport: GuardianUnixSocketTransport(
                    socketPath: stateDirectory.appending(path: "guardian.sock").path,
                    expectedPeerExecutablePath: try GuardianLocalDaemonEndpoint
                        .expectedExecutablePath()
                )
            )
            let snapshot = try await client.observeSnapshot(
                originThreadID: "codex-guardian-mac-ui",
                deadline: Date().addingTimeInterval(2)
            )
            daemonTasks = snapshot.tasks
            daemonOperations = snapshot.operations
            daemonOperationHistory = snapshot.operationHistory?.items ?? []
            daemonOperationHistoryCompleteness = snapshot.operationHistory?.completeness
            daemonOperationHistoryTotalCount = snapshot.operationHistory?.totalCount ?? 0
            daemonSnapshotCapturedAt = snapshot.capturedAt
            taskInventoryCompleteness = snapshot.taskInventoryCompleteness
            daemonStatus = snapshot.taskInventoryCompleteness == .complete
                ? "Daemon: \(snapshot.tasks.count) tasks"
                : "Daemon: observer incomplete"
        } catch {
            daemonStatus = "Daemon: unavailable"
            taskInventoryCompleteness = .incomplete
            daemonOperations = []
            daemonOperationHistory = []
            daemonOperationHistoryCompleteness = nil
            daemonOperationHistoryTotalCount = 0
        }
    }

    private func poll() {
        guard !recoveryInProgress, !automaticRecoveryBlocked else { return }
        do {
            switch recoveryDispatchPolicy.decision(
                pendingRequests: try store.peekAllPending()
            ) {
            case .idle:
                return
            case .native(let request):
                try store.claimPending(ids: [request.id])
                recoveryInProgress = true
                status = "Delivering native recovery to exact task"
                executeNativeRecovery(request)
            case .hardRestart:
                guard currentAuthorityFence()?.owner == .legacy else {
                    status = "Legacy recovery disabled; daemon owns restart"
                    automaticRecoveryBlocked = true
                    return
                }
                recoveryInProgress = true
                Task { @MainActor [weak self] in
                    await self?.waitForSafeRestart()
                }
            }
        } catch {
            status = "Invalid request: \(error.localizedDescription)"
        }
    }

    private func executeNativeRecovery(_ request: RestartRequest) {
        guard let authorityJournal, let nativeRecoveryOutbox else {
            try? store.markNativeFailed(id: request.id)
            status = "Native recovery blocked: durable state unavailable"
            recoveryInProgress = false
            return
        }
        let store = store
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (execution, launchedDesktop) = try await Task.detached(
                    priority: .userInitiated
                ) {
                    let controller = CodexProcessController(
                        requirement: .openAIProduction,
                        discovery: MacCodexProcessDiscovery()
                    )
                    let application = try controller.resolveApplication()
                    guard request.targetBundleIdentifier == application.bundleIdentifier else {
                        throw CodexProcessSelectionError.bundleIdentifierMismatch
                    }
                    let executableURL = try CodexAppServerExecutablePolicy()
                        .executableURL(for: application)
                    let runningProcess = try controller.captureRunningProcessIfPresent(
                        matching: application
                    )
                    let presenceDecision = CodexDesktopRecoveryBoundaryPolicy()
                        .decision(
                            desktopIsRunning: runningProcess != nil,
                            nativeDeliveryFailed: false,
                            inventoryIsAuthoritativeAndSafe: false
                        )
                    let launchedDesktop: Bool
                    switch presenceDecision {
                    case .launchBeforeNativeRecovery:
                        try controller.launch(application)
                        var verified = false
                        for _ in 0..<40 where !verified {
                            do {
                                _ = try controller.verifyLaunch(
                                    application: application,
                                    previous: nil
                                )
                                verified = true
                            } catch CodexProcessSelectionError.processNotFound {
                                try await Task.sleep(for: .milliseconds(250))
                            }
                        }
                        guard verified else {
                            throw CodexProcessControllerError.launchFailed
                        }
                        launchedDesktop = true
                    case .continueNativeRecovery:
                        launchedDesktop = false
                    case .automaticRestartAllowed, .humanForceRequired:
                        throw NativeRecoveryAppError
                            .automaticRestartRequiresAuthoritativeInventory
                    }
                    let executor = GuardianNativeRecoveryExecutor(
                        journal: authorityJournal,
                        outbox: nativeRecoveryOutbox,
                        store: store
                    )

                    func attempt() async throws -> GuardianNativeRecoveryExecutionResult {
                        let transport = try CodexAppServerStdioTransport(
                            executableURL: executableURL
                        )
                        defer { transport.close() }
                        return try await executor.execute(
                            request: request,
                            transport: transport,
                            deadline: Date().addingTimeInterval(600)
                        )
                    }

                    do {
                        return (try await attempt(), launchedDesktop)
                    } catch {
                        guard let token = request.originToken,
                              let stored = try store.request(originToken: token),
                              let operationID = stored.nativeOperationID,
                              try authorityJournal.outboxEntries(
                                operationID: operationID
                              ).contains(where: { $0.state == .awaitingReconciliation })
                        else { throw error }
                        do {
                            return (try await attempt(), launchedDesktop)
                        } catch {
                            let desktopIsRunning = try controller
                                .captureRunningProcessIfPresent(
                                    matching: application
                                ) != nil
                            let boundary = CodexDesktopRecoveryBoundaryPolicy()
                                .decision(
                                    desktopIsRunning: desktopIsRunning,
                                    nativeDeliveryFailed: true,
                                    inventoryIsAuthoritativeAndSafe: false
                                )
                            if boundary == .humanForceRequired {
                                throw NativeRecoveryAppError
                                    .automaticRestartRequiresAuthoritativeInventory
                            }
                            throw error
                        }
                    }
                }.value
                switch execution {
                case .delivered(_, let delivery, let alreadySubmitted):
                    if launchedDesktop {
                        status = "Codex launched; native recovery delivered; waiting for ACK"
                    } else {
                        status = alreadySubmitted
                            ? "Native recovery reconciled; waiting for exact ACK"
                            : "Native recovery delivered; waiting for exact ACK"
                    }
                    daemonStatus = "Exact task: \(delivery.threadID)"
                case .terminalFailure(_, _, _, let outcome):
                    status = "Native recovery \(outcome.rawValue); Desktop not restarted"
                }
            } catch NativeRecoveryAppError
                .automaticRestartRequiresAuthoritativeInventory {
                status = "Running Codex restart needs human Force Restart confirmation"
            } catch {
                let uncertain = request.originToken.flatMap { token in
                    try? store.request(originToken: token)
                }?.recoveryPhase == .nativeExecuting
                if uncertain {
                    status = "Native recovery uncertain; duplicate send blocked"
                } else {
                    try? store.markNativeFailed(id: request.id)
                    status = "Native recovery failed closed"
                }
            }
            recoveryInProgress = false
        }
    }

    private func waitForSafeRestart() async {
        while !Task.isCancelled {
            do {
                let requests = try store.peekAllPending()
                guard let earliestRequest = requests.map(\.requestedAt).min() else {
                    recoveryInProgress = false
                    return
                }
                guard requests.allSatisfy(\.automaticContinuationIsArmed) else {
                    status = "Restart paused: automatic continuation not armed"
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                guard automaticContinuationsReady(requests) else {
                    status = requests.contains { $0.heartbeatObservedAt == nil }
                        ? "Waiting for native recovery heartbeat"
                        : "Restart paused: recovery heartbeat changed"
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                let scanner = activityScanner
                let scanStart = activityScanStart(earliestRequest: earliestRequest)
                let scan = try await Task.detached(priority: .utility) {
                    try scanner.scan(modifiedSince: scanStart)
                }.value
                guard scan.isComplete else {
                    status = "Restart paused: task scan incomplete"
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                switch quiescencePolicy.decision(
                    requests: requests,
                    activities: scan.activities
                ) {
                case let .waitForTasks(threadIDs):
                    status = "Waiting for \(threadIDs.count) active Codex task(s)"
                case .waitForQuietPeriod:
                    status = "Waiting for Codex tasks to become quiet"
                case .restart:
                    status = "Ready; automatic Desktop boundary unavailable"
                    automaticRecoveryBlocked = true
                    recoveryInProgress = false
                    return
                }
            } catch {
                status = "Restart paused: cannot verify task activity"
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func prepareRecoveryPrompts(for requests: [RestartRequest]) async -> [RestartRequest] {
        var prepared: [RestartRequest] = []
        for request in requests {
            guard let snapshot = request.contextSnapshot, !snapshot.isEmpty else {
                prepared.append(request)
                continue
            }
#if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                status = "Understanding the last task state"
                let prompt = await AppleRecoveryPromptGenerator().generate(
                    snapshot: snapshot,
                    fallback: request.recoveryPrompt
                )
                prepared.append(request.withRecoveryPrompt(prompt))
                continue
            }
#endif
            prepared.append(request)
        }
        return prepared
    }

    private func restartCodex(
        using requests: [RestartRequest],
        claimedRequestIDs: Set<UUID> = [],
        bypassQuietGate: Bool = false
    ) {
        guard let request = requests.first else {
            recoveryInProgress = false
            return
        }
        let restartIsStillAuthorized = bypassQuietGate
            ? automaticContinuationsReady(requests)
            : automaticRestartStillSafe(requests: requests)
        if !claimedRequestIDs.isEmpty, !restartIsStillAuthorized {
            try? store.recoverClaims()
            status = "Task activity changed; restart postponed"
            recoveryInProgress = false
            poll()
            return
        }
        guard let authorityJournal else {
            try? store.recoverClaims()
            status = "Restart blocked: authority unavailable"
            automaticRecoveryBlocked = true
            recoveryInProgress = false
            return
        }
        let authorityLease: GuardianLease
        let authorityPermit: GuardianAuthorityPermit
        do {
            authorityLease = try authorityJournal.acquireLease(
                resource: GuardianAuthorityFence.cutoverLeaseResource,
                ownerID: legacyAuthorityLeaseOwnerID,
                now: Date(),
                duration: 180
            )
            authorityPermit = try authorityJournal.issueAuthorityPermit(
                owner: .legacy,
                at: Date()
            )
            try authorityJournal.validateAuthorityPermit(authorityPermit, at: Date())
        } catch {
            try? store.recoverClaims()
            status = "Restart blocked: daemon authority active"
            automaticRecoveryBlocked = true
            recoveryInProgress = false
            return
        }
        let trustRequirement = CodexProcessTrustRequirement.openAIProduction
        guard request.targetBundleIdentifier == trustRequirement.bundleIdentifier else {
            try? authorityJournal.releaseLease(authorityLease)
            try? store.recoverClaims()
            status = "Restart blocked: unexpected application identity"
            automaticRecoveryBlocked = true
            recoveryInProgress = false
            return
        }
        let processController = CodexProcessController(
            requirement: trustRequirement,
            discovery: MacCodexProcessDiscovery()
        )
        let trustedApplication: CodexApplicationCandidate
        let previousProcess: CodexRunningProcessCandidate?
        do {
            trustedApplication = try processController.resolveApplication()
            previousProcess = try processController.captureRunningProcessIfPresent(
                matching: trustedApplication
            )
        } catch {
            try? authorityJournal.releaseLease(authorityLease)
            try? store.recoverClaims()
            status = "Restart blocked: Codex process identity unavailable"
            automaticRecoveryBlocked = true
            recoveryInProgress = false
            return
        }
        let applicationPaths = [trustedApplication.bundleURLPath]
        let appServerProcessIDs = codexAppServerProcessIDs(
            applicationPaths: applicationPaths
        )
        do {
            try authorityJournal.validateAuthorityPermit(authorityPermit, at: Date())
        } catch {
            try? authorityJournal.releaseLease(authorityLease)
            try? store.recoverClaims()
            status = "Restart blocked: authority changed"
            automaticRecoveryBlocked = true
            recoveryInProgress = false
            return
        }
        if let previousProcess {
            do {
                try processController.terminate(previousProcess, force: false)
            } catch {
                try? authorityJournal.releaseLease(authorityLease)
                try? store.recoverClaims()
                status = "Restart blocked: Codex process changed"
                automaticRecoveryBlocked = true
                recoveryInProgress = false
                return
            }
            status = "Stopping verified Codex process"
        } else {
            status = "Codex stopped; preparing verified relaunch"
        }

        Task { @MainActor [weak self] in
            defer { try? authorityJournal.releaseLease(authorityLease) }
            try? await Task.sleep(for: .seconds(2))
            guard (try? authorityJournal.validateAuthorityPermit(
                authorityPermit,
                at: Date()
            )) != nil else {
                try? self?.store.recoverClaims()
                self?.status = "Restart halted: authority changed"
                self?.automaticRecoveryBlocked = true
                self?.recoveryInProgress = false
                return
            }
            if let previousProcess {
                let stopped = await self?.finishStoppingCodex(
                    captured: previousProcess,
                    controller: processController
                ) ?? false
                guard stopped else {
                    try? self?.store.recoverClaims()
                    self?.status = "Restart blocked: Codex process epoch changed"
                    self?.automaticRecoveryBlocked = true
                    self?.recoveryInProgress = false
                    return
                }
            }

            await self?.stopCodexAppServers(
                capturedProcessIDs: appServerProcessIDs,
                applicationPaths: applicationPaths
            )

            do {
                try processController.launch(trustedApplication)
            } catch {
                try? self?.store.recoverClaims()
                self?.status = "Relaunch failed: trusted Codex application changed"
                self?.automaticRecoveryBlocked = true
                self?.recoveryInProgress = false
                return
            }
            let newProcess = await self?.waitForVerifiedRelaunch(
                application: trustedApplication,
                previous: previousProcess,
                controller: processController
            )
            if let newProcess {
                self?.status = "Codex relaunched; waiting for app server"
                let startupReady = await self?.waitForRecoveryStartup(
                    process: newProcess,
                    controller: processController,
                    previousAppServerProcessIDs: appServerProcessIDs,
                    applicationPaths: applicationPaths
                ) ?? false
                guard startupReady else {
                    self?.status = "Codex relaunched; app server not ready"
                    self?.automaticRecoveryBlocked = true
                    self?.recoveryInProgress = false
                    return
                }
                var openedTaskCount = 0
                for recoveryRequest in requests where !recoveryRequest.threadID.isEmpty {
                    let opened = self?.runOpen(arguments: [
                        CodexThreadDeepLink(threadID: recoveryRequest.threadID)
                            .url.absoluteString,
                    ]) ?? false
                    if opened { openedTaskCount += 1 }
                }
                var remaining = claimedRequestIDs
                for _ in 0..<20 where !remaining.isEmpty {
                    for requestID in Array(remaining) {
                        do {
                            try self?.store.markClaimAwaitingContinuation(
                                id: requestID,
                                processIdentifier: newProcess.processID,
                                restartedAt: Date()
                            )
                            remaining.remove(requestID)
                        } catch {
                            continue
                        }
                    }
                    if !remaining.isEmpty {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                if remaining.isEmpty {
                    self?.status = claimedRequestIDs.isEmpty
                        ? "Codex relaunched"
                        : "Codex relaunched; automatic continuation ready"
                    if openedTaskCount == 0, !claimedRequestIDs.isEmpty {
                        self?.status = "Codex relaunched; heartbeat owns continuation"
                    }
                } else {
                    self?.status = "Codex relaunched; continuation state incomplete"
                    self?.automaticRecoveryBlocked = true
                }
            } else {
                try? self?.store.recoverClaims()
                self?.status = "Relaunch failed: verified Codex process unavailable"
                self?.automaticRecoveryBlocked = true
            }
            self?.recoveryInProgress = false
        }
    }

    private func automaticRestartStillSafe(requests: [RestartRequest]) -> Bool {
        guard automaticContinuationsReady(requests) else { return false }
        guard let earliestRequest = requests.map(\.requestedAt).min() else { return false }
        let scanStart = activityScanStart(earliestRequest: earliestRequest)
        guard let scan = try? activityScanner.scan(modifiedSince: scanStart),
              scan.isComplete else { return false }
        return quiescencePolicy.decision(
            requests: requests,
            activities: scan.activities
        ) == .restart
    }

    private func automaticContinuationsReady(_ requests: [RestartRequest]) -> Bool {
        hardRestartGate.canTerminate(
            requests: requests,
            verifiedAutomationIDs: verifiedAutomationIDs(for: requests)
        )
    }

    private func currentAuthorityFence() -> GuardianAuthorityFence? {
        guard let authorityJournal else { return nil }
        return try? authorityJournal.authorityFence()
    }

    private func verifiedAutomationIDs(for requests: [RestartRequest]) -> Set<String> {
        Set(requests.compactMap { request -> String? in
            guard let automationID = request.continuationAutomationID,
                  let originToken = request.originToken,
                  (try? automationVerifier.isArmed(
                    automationID: automationID,
                    threadID: request.threadID,
                    originToken: originToken
                  )) == true else { return nil }
            return automationID
        })
    }

    private func activityScanStart(earliestRequest: Date) -> Date {
        let minimumLookback = earliestRequest.addingTimeInterval(
            -quiescencePolicy.activityLookback
        )
        let codexLaunchDate = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).compactMap(\.launchDate).min()
        return min(minimumLookback, codexLaunchDate ?? minimumLookback)
    }

    private func finishStoppingCodex(
        captured: CodexRunningProcessCandidate,
        controller: CodexProcessController
    ) async -> Bool {
        do {
            if let observed = try controller.captureRunningProcessIfPresent(
                matching: captured.application
            ) {
                try CodexProcessSelectionPolicy().validateSignalTarget(
                    captured: captured,
                    observed: observed
                )
                try controller.terminate(captured, force: true)
            }
        } catch {
            do {
                return try controller.captureRunningProcessIfPresent(
                    matching: captured.application
                ) == nil
            } catch {
                return false
            }
        }

        for _ in 0..<20 {
            do {
                guard let observed = try controller.captureRunningProcessIfPresent(
                    matching: captured.application
                ) else {
                    return true
                }
                try CodexProcessSelectionPolicy().validateSignalTarget(
                    captured: captured,
                    observed: observed
                )
            } catch {
                return false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func waitForVerifiedRelaunch(
        application: CodexApplicationCandidate,
        previous: CodexRunningProcessCandidate?,
        controller: CodexProcessController
    ) async -> CodexRunningProcessCandidate? {
        for _ in 0..<40 {
            do {
                return try controller.verifyLaunch(
                    application: application,
                    previous: previous
                )
            } catch CodexProcessSelectionError.processNotFound,
                    CodexProcessControllerError.processDidNotRestart {
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func runOpen(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func codexAppServerProcessIDs(applicationPaths: [String]) -> Set<Int32> {
        do {
            let data = try ProcessOutputCapture(maximumBytes: 2_000_000).run(
                executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,command="]
            )
            guard let processList = String(data: data, encoding: .utf8) else { return [] }
            return CodexAppServerProcessPolicy().processIDsToStop(
                processList: processList,
                applicationPaths: applicationPaths
            )
        } catch {
            return []
        }
    }

    private func waitForRecoveryStartup(
        process: CodexRunningProcessCandidate,
        controller: CodexProcessController,
        previousAppServerProcessIDs: Set<Int32>,
        applicationPaths: [String]
    ) async -> Bool {
        var tracker = CodexRecoveryStartupTracker()
        for _ in 0..<150 {
            let desktopIsRunning: Bool
            do {
                let observed = try controller.captureRunningProcess(
                    matching: process.application
                )
                try CodexProcessSelectionPolicy().validateSignalTarget(
                    captured: process,
                    observed: observed
                )
                desktopIsRunning = true
            } catch {
                desktopIsRunning = false
            }
            let newAppServerProcessIDs = codexAppServerProcessIDs(
                applicationPaths: applicationPaths
            ).subtracting(previousAppServerProcessIDs)
            if tracker.shouldStartContinuation(
                desktopIsRunning: desktopIsRunning,
                appServerIsRunning: !newAppServerProcessIDs.isEmpty,
                now: Date()
            ) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func stopCodexAppServers(
        capturedProcessIDs: Set<Int32>,
        applicationPaths: [String]
    ) async {
        let stillMatching = codexAppServerProcessIDs(applicationPaths: applicationPaths)
        let targets = capturedProcessIDs.intersection(stillMatching)
        targets.forEach { Darwin.kill($0, SIGTERM) }
        try? await Task.sleep(for: .seconds(1))
        let remaining = codexAppServerProcessIDs(applicationPaths: applicationPaths)
        targets.intersection(remaining).forEach { Darwin.kill($0, SIGKILL) }
    }
}
