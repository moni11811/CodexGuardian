import Foundation

public enum CodexAppServerExecutablePolicyError: Error, Equatable, Sendable {
    case invalidBundlePath
    case executableEscapesBundle
    case executableUnavailable
}

public struct CodexAppServerExecutablePolicy: Sendable {
    public init() {}

    public func executableURL(
        for application: CodexApplicationCandidate
    ) throws -> URL {
        guard application.bundleURLPath.hasPrefix("/") else {
            throw CodexAppServerExecutablePolicyError.invalidBundlePath
        }

        let bundleURL = URL(
            fileURLWithPath: application.bundleURLPath,
            isDirectory: true
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
        let executableURL = bundleURL
            .appending(path: "Contents/Resources/codex")
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isDescendant(executableURL, of: bundleURL) else {
            throw CodexAppServerExecutablePolicyError.executableEscapesBundle
        }

        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(
            atPath: executableURL.path
        )
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw CodexAppServerExecutablePolicyError.executableUnavailable
        }
        return executableURL
    }

    private func isDescendant(_ itemURL: URL, of directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.path
        let descendantPrefix = directoryPath == "/"
            ? directoryPath
            : directoryPath + "/"
        return itemURL.path.hasPrefix(descendantPrefix)
    }
}
