import Foundation

public struct CodexContinuationLauncher: Sendable {
    public init() {}

    public func start(
        request: RestartRequest,
        executableURL: URL,
        logURL: URL
    ) throws -> Process {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = CodexResumePlan(request: request).arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return process
    }
}
