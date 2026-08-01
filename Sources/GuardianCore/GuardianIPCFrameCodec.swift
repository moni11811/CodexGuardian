import Foundation

public enum GuardianIPCFrameError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge(Int)
}

public enum GuardianIPCFrameCodec {
    public static let defaultMaximumBytes = 1_048_576

    public static func encode(
        _ payload: Data,
        maximumBytes: Int = defaultMaximumBytes
    ) throws -> Data {
        guard !payload.isEmpty else {
            throw GuardianIPCFrameError.emptyPayload
        }
        guard payload.count <= maximumBytes, payload.count <= Int(UInt32.max) else {
            throw GuardianIPCFrameError.payloadTooLarge(payload.count)
        }
        let length = UInt32(payload.count)
        var framed = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        framed.append(payload)
        return framed
    }
}

public struct GuardianIPCFrameDecoder: Sendable {
    private var buffer = Data()
    public let maximumBytes: Int

    public init(maximumBytes: Int = GuardianIPCFrameCodec.defaultMaximumBytes) {
        self.maximumBytes = maximumBytes
    }

    public mutating func append<S: DataProtocol>(_ chunk: S) throws -> [Data] {
        buffer.append(contentsOf: chunk)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            guard length > 0 else {
                throw GuardianIPCFrameError.emptyPayload
            }
            guard length <= UInt32(maximumBytes) else {
                throw GuardianIPCFrameError.payloadTooLarge(Int(length))
            }
            let frameLength = 4 + Int(length)
            guard buffer.count >= frameLength else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let frameEnd = buffer.index(payloadStart, offsetBy: Int(length))
            frames.append(Data(buffer[payloadStart..<frameEnd]))
            buffer.removeSubrange(buffer.startIndex..<frameEnd)
        }
        return frames
    }
}
