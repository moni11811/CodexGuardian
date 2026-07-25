import Foundation

public enum CodexContinuationLauncherError: Error {
    case detachedCLIForbidden
}

public struct CodexContinuationLauncher: Sendable {
    public init() {}

    public func start(
        request: RestartRequest,
        executableURL: URL,
        logURL: URL
    ) throws -> Process {
        throw CodexContinuationLauncherError.detachedCLIForbidden
    }
}
