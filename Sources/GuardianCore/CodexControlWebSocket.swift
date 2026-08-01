import CryptoKit
import Foundation

/// Minimal RFC 6455 codec for the Desktop control socket.
/// Transport ownership and JSON-RPC stay outside this type.
public enum CodexControlWebSocket {
    public enum Opcode: UInt8, Sendable {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    public struct ServerFrame: Equatable, Sendable {
        public let opcode: Opcode
        public let isFinal: Bool
        public let payload: Data
        public let bytesConsumed: Int
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidHandshake
        case invalidAccept
        case invalidFrame
        case unsupportedFrame
        case invalidMaskingKey
    }

    public static func handshakeRequest(host: String, path: String, key: String) -> Data {
        Data(([
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "",
            "",
        ].joined(separator: "\r\n")).utf8)
    }

    public static func validateHandshakeResponse(_ response: Data, key: String) throws -> Bool {
        guard let text = String(data: response, encoding: .utf8) else { throw Error.invalidHandshake }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first,
              status.split(separator: " ").dropFirst().first == "101"
        else { throw Error.invalidHandshake }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Error.invalidHandshake }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true,
              headers["sec-websocket-accept"] == websocketAccept(for: key)
        else { throw Error.invalidAccept }
        return true
    }

    public static func clientTextFrame(_ text: String, maskingKey: [UInt8]) throws -> Data {
        guard maskingKey.count == 4 else { throw Error.invalidMaskingKey }
        let payload = Array(text.utf8)
        var frame = Data([0x81])
        if payload.count <= 125 {
            frame.append(UInt8(0x80 | payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0xFE)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            throw Error.unsupportedFrame
        }
        frame.append(contentsOf: maskingKey)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ maskingKey[index % maskingKey.count])
        }
        return frame
    }

    /// Decodes one unmasked server frame. Returns nil until the full frame arrives.
    public static func decodeServerFrame(_ bytes: Data) -> ServerFrame? {
        let input = Array(bytes)
        guard input.count >= 2 else { return nil }
        let first = input[0]
        let second = input[1]
        guard second & 0x80 == 0,
              let opcode = Opcode(rawValue: first & 0x0F)
        else { return nil }
        var offset = 2
        var length = Int(second & 0x7F)
        if length == 126 {
            guard input.count >= offset + 2 else { return nil }
            length = Int(input[offset]) << 8 | Int(input[offset + 1])
            offset += 2
        } else if length == 127 {
            guard input.count >= offset + 8 else { return nil }
            var value: UInt64 = 0
            for byte in input[offset..<(offset + 8)] {
                value = value << 8 | UInt64(byte)
            }
            guard value <= UInt64(Int.max) else { return nil }
            length = Int(value)
            offset += 8
        }
        guard input.count >= offset + length else { return nil }
        return ServerFrame(
            opcode: opcode,
            isFinal: first & 0x80 != 0,
            payload: Data(input[offset..<(offset + length)]),
            bytesConsumed: offset + length
        )
    }

    private static func websocketAccept(for key: String) -> String {
        let source = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: source)).base64EncodedString()
    }
}
