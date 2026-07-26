import AppKit
import Combine
import Darwin
import Foundation
import GuardianCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status = "Watching for MCP requests"

    private let store = RestartRequestStore()
    private let activityScanner = CodexTaskActivityScanner()
    private let quiescencePolicy = RestartQuiescencePolicy()
    private let automationVerifier = CodexRecoveryAutomationVerifier()
    private let hardRestartGate = HardRestartGate()
    private var timer: Timer?
    private var recoveryInProgress = false
    private var automaticRecoveryBlocked = false

    init() {
        try? store.recoverClaims()
        if let blocked = try? store.quarantineUnarmedPendingRequests(), !blocked.isEmpty {
            status = "Preserved \(blocked.count) legacy restart request(s)"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func requestManualRecovery() {
        guard !recoveryInProgress else { return }
        automaticRecoveryBlocked = false
        recoveryInProgress = true
        status = "Force restarting Codex"
        restartCodex(using: [RestartRequest(delaySeconds: 1)])
    }

    private func poll() {
        guard !recoveryInProgress, !automaticRecoveryBlocked else { return }
        do {
            guard !(try store.peekAllPending()).isEmpty else { return }
            recoveryInProgress = true
            Task { @MainActor [weak self] in
                await self?.waitForSafeRestart()
            }
        } catch {
            status = "Invalid request: \(error.localizedDescription)"
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
                    status = "Preparing recovery prompts"
                    let prepared = await prepareRecoveryPrompts(for: requests)
                    let currentRequests = try store.peekAllPending()
                    guard Set(currentRequests.map(\.id)) == Set(requests.map(\.id)) else {
                        status = "New recovery request found; checking tasks again"
                        continue
                    }
                    let finalScan = try await Task.detached(priority: .utility) {
                        try scanner.scan(modifiedSince: scanStart)
                    }.value
                    guard finalScan.isComplete,
                          quiescencePolicy.decision(
                            requests: currentRequests,
                            activities: finalScan.activities
                          ) == .restart else {
                        status = "Task activity changed; restart postponed"
                        continue
                    }
                    let claimedIDs = Set(requests.map(\.id))
                    do {
                        try store.claimPending(ids: claimedIDs)
                        try store.updateClaimedRequests(prepared)
                    } catch {
                        try? store.recoverClaims()
                        throw error
                    }
                    restartCodex(using: prepared, claimedRequestIDs: claimedIDs)
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
        claimedRequestIDs: Set<UUID> = []
    ) {
        guard let request = requests.first else {
            recoveryInProgress = false
            return
        }
        if !claimedRequestIDs.isEmpty,
           !automaticRestartStillSafe(requests: requests) {
            try? store.recoverClaims()
            status = "Task activity changed; restart postponed"
            recoveryInProgress = false
            poll()
            return
        }
        let launchPlan = CodexLaunchPlan(bundleIdentifier: request.targetBundleIdentifier)
        let resolvedApplicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: request.targetBundleIdentifier
        )
        guard resolvedApplicationURL != nil || launchPlan.fallbackApplicationPaths.contains(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            try? store.recoverClaims()
            status = "Codex application not found"
            automaticRecoveryBlocked = true
            recoveryInProgress = false
            return
        }

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: request.targetBundleIdentifier
        )
        let previousProcessIDs = Set(running.map(\.processIdentifier))
        var applicationPaths = launchPlan.fallbackApplicationPaths
        if let resolvedApplicationURL {
            applicationPaths.append(resolvedApplicationURL.path)
        }
        let appServerProcessIDs = codexAppServerProcessIDs(
            applicationPaths: applicationPaths
        )
        running.forEach { $0.terminate() }
        status = "Stopping Codex"

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            running.filter(\.isTerminated.negated).forEach { $0.forceTerminate() }

            for _ in 0..<20 where !NSRunningApplication.runningApplications(
                withBundleIdentifier: request.targetBundleIdentifier
            ).isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }

            await self?.stopCodexAppServers(
                capturedProcessIDs: appServerProcessIDs,
                applicationPaths: applicationPaths
            )

            let didLaunch = await self?.launchCodex(
                plan: launchPlan,
                resolvedApplicationURL: resolvedApplicationURL
            ) ?? false
            let currentApplications = NSRunningApplication.runningApplications(
                withBundleIdentifier: request.targetBundleIdentifier
            )
            let currentProcessIDs = Set(currentApplications.map(\.processIdentifier))
            let newProcessID = currentProcessIDs.subtracting(previousProcessIDs).first
            let didRestart = didLaunch && CodexRelaunchPolicy().didRestart(
                previousProcessIDs: previousProcessIDs,
                currentProcessIDs: currentProcessIDs
            )
            if didRestart, let newProcessID {
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
                                processIdentifier: newProcessID,
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
                self?.status = didLaunch
                    ? "Restart failed: old Codex process remained"
                    : "Relaunch failed: Codex application not found"
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
        let verifiedIDs = Set(requests.compactMap { request -> String? in
            guard let automationID = request.continuationAutomationID,
                  let originToken = request.originToken,
                  (try? automationVerifier.isArmed(
                    automationID: automationID,
                    threadID: request.threadID,
                    originToken: originToken
                  )) == true else { return nil }
            return automationID
        })
        return hardRestartGate.canTerminate(
            requests: requests,
            verifiedAutomationIDs: verifiedIDs
        )
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

    private func launchCodex(
        plan: CodexLaunchPlan,
        resolvedApplicationURL: URL?
    ) async -> Bool {
        let policy = CodexRelaunchPolicy()
        for _ in 0..<3 {
            let opened = runOpen(arguments: ["-b", plan.bundleIdentifier])
            try? await Task.sleep(for: .seconds(1))
            let running = !NSRunningApplication.runningApplications(
                withBundleIdentifier: plan.bundleIdentifier
            ).isEmpty
            if policy.isRecovered(openSucceeded: opened, applicationIsRunning: running) {
                return true
            }
        }

        var candidatePaths = plan.fallbackApplicationPaths
        if let resolvedApplicationURL {
            candidatePaths.insert(resolvedApplicationURL.path, at: 0)
        }

        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            for _ in 0..<3 {
                let opened = runOpen(arguments: ["-n", path])
                try? await Task.sleep(for: .seconds(1))
                let running = !NSRunningApplication.runningApplications(
                    withBundleIdentifier: plan.bundleIdentifier
                ).isEmpty
                if policy.isRecovered(openSucceeded: opened, applicationIsRunning: running) {
                    return true
                }
            }
        }
        return false
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

private extension Bool {
    var negated: Bool { !self }
}
