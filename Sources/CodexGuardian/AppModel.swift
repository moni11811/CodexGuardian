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

            let resumable = requests.filter { !$0.threadID.isEmpty }
            let resumed = resumable.filter { self?.startContinuation(for: $0) == true }.count
            let didLaunch = self?.launchCodex(
                plan: launchPlan,
                resolvedApplicationURL: resolvedApplicationURL
            ) ?? false
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
    ) -> Bool {
        if runOpen(arguments: ["-b", plan.bundleIdentifier]) {
            return true
        }

        var candidatePaths = plan.fallbackApplicationPaths
        if let resolvedApplicationURL {
            candidatePaths.insert(resolvedApplicationURL.path, at: 0)
        }

        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            if runOpen(arguments: [path]) {
                return true
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
