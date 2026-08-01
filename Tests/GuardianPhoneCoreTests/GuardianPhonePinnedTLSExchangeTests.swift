import Foundation
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone pinned TLS exchange")
struct GuardianPhonePinnedTLSExchangeTests {
    @Test("exchange pins the exact endpoint and reconstructs one fragmented response")
    func fragmentedResponse() async throws {
        let endpoint = PhonePinnedEndpoint(
            host: "192.168.1.20",
            port: 47_411,
            tlsCertificateHash: Data(repeating: 0x42, count: 32)
        )
        let request = frame(Data("request".utf8))
        let response = frame(Data("response".utf8))
        let connection = ScriptedPhonePinnedConnection(chunks: [
            .init(data: Data(response.prefix(1)), isComplete: false),
            .init(data: Data(response.dropFirst(1).prefix(3)), isComplete: false),
            .init(data: Data(response.dropFirst(4).prefix(2)), isComplete: false),
            .init(data: Data(response.dropFirst(6)), isComplete: true),
        ])
        let factory = RecordingPhonePinnedConnectionFactory(connection: connection)
        let exchange = PhonePinnedTLSExchange(factory: factory, timeout: 2)

        let received = try await exchange(endpoint: endpoint, requestFrame: request)

        #expect(received == response)
        #expect(factory.endpoint == endpoint)
        #expect(connection.started)
        #expect(connection.sent == [request])
        #expect(connection.cancelled)
    }

    @Test("oversized response is rejected before its body is read")
    func oversizedResponse() async throws {
        let maximum = PhonePinnedTLSExchange.maximumFrameBytes
        let length = UInt32(maximum + 1)
        let header = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        let connection = ScriptedPhonePinnedConnection(chunks: [
            .init(data: header, isComplete: false),
        ])
        let factory = RecordingPhonePinnedConnectionFactory(connection: connection)
        let exchange = PhonePinnedTLSExchange(factory: factory, timeout: 2)

        await #expect(throws: PhonePinnedTLSExchangeError.oversizedFrame) {
            _ = try await exchange(
                endpoint: .init(
                    host: "192.168.1.20",
                    port: 47_411,
                    tlsCertificateHash: Data(repeating: 0x42, count: 32)
                ),
                requestFrame: frame(Data("request".utf8))
            )
        }
        #expect(connection.receiveCount == 1)
        #expect(connection.cancelled)
    }

    private func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        return Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]) + payload
    }
}

private final class RecordingPhonePinnedConnectionFactory:
    PhonePinnedConnectionFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let connection: any PhonePinnedConnection
    private var recordedEndpoint: PhonePinnedEndpoint?

    init(connection: any PhonePinnedConnection) {
        self.connection = connection
    }

    var endpoint: PhonePinnedEndpoint? {
        lock.withLock { recordedEndpoint }
    }

    func makeConnection(to endpoint: PhonePinnedEndpoint) throws -> any PhonePinnedConnection {
        lock.withLock { recordedEndpoint = endpoint }
        return connection
    }
}

private final class ScriptedPhonePinnedConnection: PhonePinnedConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [PhonePinnedConnectionChunk]
    private var didStart = false
    private var sentFrames: [Data] = []
    private var didCancel = false
    private var receives = 0

    init(chunks: [PhonePinnedConnectionChunk]) {
        self.chunks = chunks
    }

    var started: Bool { lock.withLock { didStart } }
    var sent: [Data] { lock.withLock { sentFrames } }
    var cancelled: Bool { lock.withLock { didCancel } }
    var receiveCount: Int { lock.withLock { receives } }

    func start() async throws {
        lock.withLock { didStart = true }
    }

    func send(_ data: Data) async throws {
        lock.withLock { sentFrames.append(data) }
    }

    func receive(maximumLength: Int) async throws -> PhonePinnedConnectionChunk {
        try lock.withLock {
            receives += 1
            guard !chunks.isEmpty else { throw PhonePinnedTLSExchangeError.connectionClosed }
            let chunk = chunks.removeFirst()
            guard chunk.data.count <= maximumLength else {
                throw PhonePinnedTLSExchangeError.invalidFrame
            }
            return chunk
        }
    }

    func cancel() {
        lock.withLock { didCancel = true }
    }
}
