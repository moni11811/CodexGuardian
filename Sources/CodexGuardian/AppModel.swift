import AppKit
import Combine
import Foundation
import GuardianCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status = "Watching for MCP requests"

    private let store = RestartRequestStore()
    private var timer: Timer?
    private var recoveryInProgress = false

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func requestManualRecovery() {
        do {
            try store.enqueue(RestartRequest())
            status = "Restart scheduled"
            poll()
        } catch {
            status = "Could not schedule: \(error.localizedDescription)"
        }
    }

    private func poll() {
        guard !recoveryInProgress else { return }
        do {
            let requests = try store.takeAllPending()
            guard let first = requests.first else { return }
            recoveryInProgress = true
            status = "Restarting Codex in \(first.delaySeconds)s"
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(first.delaySeconds))
                let laterRequests = (try? self?.store.takeAllPending()) ?? []
                guard let self else { return }
                let prepared = await self.prepareRecoveryPrompts(for: requests + laterRequests)
                self.restartCodex(using: prepared)
            }
        } catch {
            status = "Invalid request: \(error.localizedDescription)"
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

    private func restartCodex(using requests: [RestartRequest]) {
        guard let request = requests.first else {
            recoveryInProgress = false
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(request.recoveryPrompt, forType: .string)

        let launchPlan = CodexLaunchPlan(bundleIdentifier: request.targetBundleIdentifier)
        let resolvedApplicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: request.targetBundleIdentifier
        )
        guard resolvedApplicationURL != nil || launchPlan.fallbackApplicationPaths.contains(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            status = "Codex application not found"
            recoveryInProgress = false
            return
        }

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: request.targetBundleIdentifier
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

            let didLaunch = await self?.launchCodex(
                plan: launchPlan,
                resolvedApplicationURL: resolvedApplicationURL
            ) ?? false
            let resumable = requests.filter { !$0.threadID.isEmpty }
            let startupPolicy = CodexRecoveryStartupPolicy()
            var resumed = 0
            if startupPolicy.shouldStartContinuation(desktopIsRunning: didLaunch) {
                try? await Task.sleep(for: .seconds(startupPolicy.continuationDelaySeconds))
                resumed = resumable.filter { self?.startContinuation(for: $0) == true }.count
            }
            self?.status = didLaunch
                ? "Codex relaunched; continuing \(resumed)/\(resumable.count) tasks"
                : "Relaunch failed: Codex application not found"
            self?.recoveryInProgress = false
        }
    }

    private func startContinuation(for request: RestartRequest) -> Bool {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        guard let executable = candidates.first(where: FileManager.default.fileExists(atPath:)) else {
            return false
        }

        let logs = store.directory.appending(path: "logs", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let logURL = logs.appending(path: "\(request.id.uuidString).jsonl")
            _ = try CodexContinuationLauncher().start(
                request: request,
                executableURL: URL(fileURLWithPath: executable),
                logURL: logURL
            )
            return true
        } catch {
            return false
        }
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
}

private extension Bool {
    var negated: Bool { !self }
}
