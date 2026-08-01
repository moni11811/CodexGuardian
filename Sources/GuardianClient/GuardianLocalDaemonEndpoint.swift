import Foundation

public enum GuardianLocalDaemonEndpoint {
    public static func expectedExecutablePath(
        currentExecutablePath: String = CommandLine.arguments[0],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let override = environment["CODEX_GUARDIAN_EXPECTED_DAEMON_PATH"],
           override.hasPrefix("/"),
           FileManager.default.fileExists(atPath: override) {
            return override
        }

        let executable = URL(fileURLWithPath: currentExecutablePath)
            .resolvingSymlinksInPath()
        let parent = executable.deletingLastPathComponent()
        let candidate: URL
        if parent.lastPathComponent == "SharedSupport" {
            candidate = parent.appending(path: "guardian-daemon")
        } else if parent.lastPathComponent == "MacOS" {
            candidate = parent.deletingLastPathComponent()
                .appending(path: "SharedSupport/guardian-daemon")
        } else {
            candidate = parent.appending(path: "guardian-daemon")
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw GuardianUnixSocketError.untrustedPeer
        }
        return candidate.path
    }
}
