import Darwin
import Foundation
import GuardianCore

public enum GuardianUnixSocketError: Error, Equatable, Sendable {
    case invalidSocketPath
    case untrustedSocket
    case untrustedPeer
    case systemCall(String, Int32)
    case deadlineExceeded
    case connectionClosed
    case oversizedReply
}

public struct GuardianUnixSocketTransport: GuardianClientTransport, Sendable {
    public let socketPath: String
    public let maximumReplyBytes: Int
    public let expectedPeerExecutablePath: String?

    public init(
        socketPath: String,
        maximumReplyBytes: Int = GuardianIPCFrameCodec.defaultMaximumBytes,
        expectedPeerExecutablePath: String? = nil
    ) {
        self.socketPath = socketPath
        self.maximumReplyBytes = maximumReplyBytes
        self.expectedPeerExecutablePath = expectedPeerExecutablePath
    }

    public func exchange(frame: Data, deadline: Date) async throws -> Data {
        let path = socketPath
        let maximumBytes = maximumReplyBytes
        let expectedPeerExecutablePath = expectedPeerExecutablePath
        return try await Task.detached(priority: .userInitiated) {
            try Self.blockingExchange(
                frame: frame,
                socketPath: path,
                maximumReplyBytes: maximumBytes,
                expectedPeerExecutablePath: expectedPeerExecutablePath,
                deadline: deadline
            )
        }.value
    }

    private static func blockingExchange(
        frame: Data,
        socketPath: String,
        maximumReplyBytes: Int,
        expectedPeerExecutablePath: String?,
        deadline: Date
    ) throws -> Data {
        try verifySocket(path: socketPath)
        guard deadline > Date() else { throw GuardianUnixSocketError.deadlineExceeded }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw GuardianUnixSocketError.systemCall("socket", errno)
        }
        defer { Darwin.close(descriptor) }
        var noPipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        try setTimeout(on: descriptor, deadline: deadline)
        try connect(descriptor: descriptor, path: socketPath)
        if let expectedPeerExecutablePath {
            try GuardianUnixPeerIdentity.verify(
                descriptor: descriptor,
                expectedExecutablePath: expectedPeerExecutablePath
            )
        }
        try writeAll(frame, to: descriptor)
        let header = try readExactly(4, from: descriptor)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumReplyBytes) else {
            throw GuardianUnixSocketError.oversizedReply
        }
        let payload = try readExactly(Int(length), from: descriptor)
        return header + payload
    }

    private static func verifySocket(path: String) throws {
        guard !path.isEmpty, path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw GuardianUnixSocketError.invalidSocketPath
        }
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFSOCK,
              status.st_mode & 0o077 == 0 else {
            throw GuardianUnixSocketError.untrustedSocket
        }
    }

    private static func setTimeout(on descriptor: Int32, deadline: Date) throws {
        let remaining = max(0.001, deadline.timeIntervalSinceNow)
        var timeout = timeval(
            tv_sec: Int(remaining),
            tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        for option in [SO_SNDTIMEO, SO_RCVTIMEO] {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw GuardianUnixSocketError.systemCall("setsockopt", errno)
            }
        }
    }

    private static func connect(descriptor: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strlcpy(destination, source, pathCapacity)
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(length)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            throw mapSystemError("connect")
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else { throw mapSystemError("write") }
                offset += count
            }
        }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < count {
                let received = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if received == 0 { throw GuardianUnixSocketError.connectionClosed }
                guard received > 0 else { throw mapSystemError("read") }
                offset += received
            }
        }
        return data
    }

    private static func mapSystemError(_ call: String) -> GuardianUnixSocketError {
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
            return .deadlineExceeded
        }
        return .systemCall(call, errno)
    }
}
