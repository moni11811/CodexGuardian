import Foundation

public enum ProcessOutputCaptureError: Error, Equatable, Sendable {
    case nonzeroExit(Int32)
    case outputTooLarge
}

public struct ProcessOutputCapture: Sendable {
    public let maximumBytes: Int

    public init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    public func run(
        executableURL: URL,
        arguments: [String]
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ProcessOutputCaptureError.nonzeroExit(process.terminationStatus)
        }
        guard data.count <= maximumBytes else {
            throw ProcessOutputCaptureError.outputTooLarge
        }
        return data
    }
}
