import Darwin
import Foundation

public enum GuardianSocketIOError: Error, Equatable, Sendable {
    case deadlineExceeded
    case connectionClosed
    case invalidCount
    case systemCall(String, Int32)
}

public enum GuardianSocketIO {
    public static func configure(descriptor: Int32, deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw GuardianSocketIOError.deadlineExceeded }
        let bounded = max(0.001, remaining)
        var timeout = timeval(
            tv_sec: Int(bounded),
            tv_usec: Int32((bounded.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw GuardianSocketIOError.systemCall("setsockopt", errno)
            }
        }
    }

    public static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        guard count >= 0 else { throw GuardianSocketIOError.invalidCount }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < count {
                let received = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if received > 0 {
                    offset += received
                    continue
                }
                if received == 0 { throw GuardianSocketIOError.connectionClosed }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                    throw GuardianSocketIOError.deadlineExceeded
                }
                throw GuardianSocketIOError.systemCall("read", errno)
            }
        }
        return data
    }

    public static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent < 0, errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                    throw GuardianSocketIOError.deadlineExceeded
                }
                throw GuardianSocketIOError.systemCall("write", errno)
            }
        }
    }
}
