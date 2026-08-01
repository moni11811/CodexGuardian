import Foundation
import Testing
@testable import GuardianCore

@Test func controlSocketHandshakeUsesAndValidatesWebSocketUpgrade() throws {
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    let request = CodexControlWebSocket.handshakeRequest(
        host: "localhost",
        path: "/",
        key: key
    )
    let requestText = String(decoding: request, as: UTF8.self)

    #expect(requestText.hasPrefix("GET / HTTP/1.1\r\n"))
    #expect(requestText.contains("Host: localhost\r\n"))
    #expect(requestText.contains("Upgrade: websocket\r\n"))
    #expect(requestText.contains("Connection: Upgrade\r\n"))
    #expect(requestText.contains("Sec-WebSocket-Key: \(key)\r\n"))
    #expect(requestText.hasSuffix("\r\n\r\n"))

    let responseText = "HTTP/1.1 101 Switching Protocols\r\n"
        + "Upgrade: websocket\r\n"
        + "Connection: Upgrade\r\n"
        + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
        + "\r\n"
    let response = Data(responseText.utf8)

    #expect(try CodexControlWebSocket.validateHandshakeResponse(response, key: key))
}

@Test func clientTextFrameUsesRFC6455Masking() throws {
    let frame = try CodexControlWebSocket.clientTextFrame(
        "Hello",
        maskingKey: [0x37, 0xfa, 0x21, 0x3d]
    )

    #expect(Array(frame) == [
        0x81, 0x85,
        0x37, 0xfa, 0x21, 0x3d,
        0x7f, 0x9f, 0x4d, 0x51, 0x58,
    ])
}

@Test func serverTextFrameDecodesWithoutLosingTrailingBytes() throws {
    let bytes = Data([0x81, 0x05] + Array("Hello".utf8) + [0x81, 0x00])
    let frame = try #require(CodexControlWebSocket.decodeServerFrame(bytes))

    #expect(frame.opcode == .text)
    #expect(frame.isFinal)
    #expect(String(decoding: frame.payload, as: UTF8.self) == "Hello")
    #expect(frame.bytesConsumed == 7)
}

@Test func incompleteServerFrameWaitsForMoreBytes() throws {
    let bytes = Data([0x81, 0x05] + Array("Hel".utf8))

    #expect(CodexControlWebSocket.decodeServerFrame(bytes) == nil)
}
