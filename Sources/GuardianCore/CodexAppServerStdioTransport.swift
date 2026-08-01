#if os(macOS)
import Darwin
import Foundation

public enum CodexAppServerStdioTransportError: Error, Equatable, Sendable {
    case invalidRequest
    case deadlineExceeded
    case connectionClosed
    case oversizedMessage
    case systemCall(String, Int32)
}

/// Independent JSONL transport for `codex app-server --stdio`.
/// Calls are serialized so responses and notifications remain correlated.
public final class CodexAppServerStdioTransport: @unchecked Sendable,
    CodexAppServerRecoveryTransport {
    private let lock = NSLock()
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let maximumMessageBytes: Int
    private var readBuffer = Data()
    private var pendingMessages: [Data] = []
    private var isClosed = false

    public init(
        executableURL: URL,
        arguments: [String] = ["app-server", "--stdio"],
        environment: [String: String]? = nil,
        maximumMessageBytes: Int = 2_000_000
    ) throws {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              maximumMessageBytes > 0 else {
            throw CodexAppServerStdioTransportError.invalidRequest
        }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.maximumMessageBytes = maximumMessageBytes
        try process.run()
    }

    deinit {
        close()
    }

    public func exchange(request: Data, deadline: Date) throws -> Data {
        try lock.withLock {
            let requestID = try Self.requestID(request)
            try writeLine(request, deadline: deadline)
            while true {
                let message = try nextLine(deadline: deadline)
                if Self.responseID(message) == requestID { return message }
                pendingMessages.append(message)
            }
        }
    }

    public func send(notification: Data, deadline: Date) throws {
        try lock.withLock {
            try writeLine(notification, deadline: deadline)
        }
    }

    public func receive(deadline: Date) throws -> Data {
        try lock.withLock {
            if !pendingMessages.isEmpty { return pendingMessages.removeFirst() }
            return try nextLine(deadline: deadline)
        }
    }

    public func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            try? input.close()
            if process.isRunning { process.terminate() }
            try? output.close()
        }
    }

    private func writeLine(_ message: Data, deadline: Date) throws {
        guard !isClosed,
              !message.isEmpty,
              message.count <= maximumMessageBytes,
              (try? JSONSerialization.jsonObject(with: message)) != nil else {
            throw CodexAppServerStdioTransportError.invalidRequest
        }
        var line = message
        line.append(0x0A)
        try writeAll(line, descriptor: input.fileDescriptor, deadline: deadline)
    }

    private func nextLine(deadline: Date) throws -> Data {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard line.count <= maximumMessageBytes else {
                    throw CodexAppServerStdioTransportError.oversizedMessage
                }
                return line
            }
            guard readBuffer.count <= maximumMessageBytes else {
                throw CodexAppServerStdioTransportError.oversizedMessage
            }
            try wait(
                descriptor: output.fileDescriptor,
                events: Int16(POLLIN),
                deadline: deadline
            )
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                readBuffer.append(contentsOf: bytes.prefix(count))
                continue
            }
            if count == 0 { throw CodexAppServerStdioTransportError.connectionClosed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                throw CodexAppServerStdioTransportError.deadlineExceeded
            }
            throw CodexAppServerStdioTransportError.systemCall("read", errno)
        }
    }

    private func writeAll(
        _ data: Data,
        descriptor: Int32,
        deadline: Date
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                try wait(
                    descriptor: descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline
                )
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                    throw CodexAppServerStdioTransportError.deadlineExceeded
                }
                throw CodexAppServerStdioTransportError.systemCall("write", errno)
            }
        }
    }

    private func wait(
        descriptor: Int32,
        events: Int16,
        deadline: Date
    ) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexAppServerStdioTransportError.deadlineExceeded
            }
            let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, milliseconds)
            if result > 0 {
                guard item.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                    throw CodexAppServerStdioTransportError.connectionClosed
                }
                return
            }
            if result == 0 {
                throw CodexAppServerStdioTransportError.deadlineExceeded
            }
            if errno == EINTR { continue }
            throw CodexAppServerStdioTransportError.systemCall("poll", errno)
        }
    }

    private static func requestID(_ data: Data) throws -> Int {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.intValue else {
            throw CodexAppServerStdioTransportError.invalidRequest
        }
        return id
    }

    private static func responseID(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard object["method"] == nil,
              object["result"] != nil || object["error"] != nil else {
            return nil
        }
        return (object["id"] as? NSNumber)?.intValue
    }
}
#endif
