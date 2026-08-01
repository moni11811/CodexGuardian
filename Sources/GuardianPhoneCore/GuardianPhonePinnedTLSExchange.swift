import Foundation
import Network
import Security

public struct PhonePinnedConnectionChunk: Equatable, Sendable {
    public let data: Data
    public let isComplete: Bool

    public init(data: Data, isComplete: Bool) {
        self.data = data
        self.isComplete = isComplete
    }
}

public protocol PhonePinnedConnection: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    func receive(maximumLength: Int) async throws -> PhonePinnedConnectionChunk
    func cancel()
}

public protocol PhonePinnedConnectionFactory: Sendable {
    func makeConnection(to endpoint: PhonePinnedEndpoint) throws -> any PhonePinnedConnection
}

public enum PhonePinnedTLSExchangeError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidTimeout
    case invalidFrame
    case oversizedFrame
    case connectionClosed
    case timedOut
}

public struct PhonePinnedTLSExchange: Sendable {
    public static let maximumFrameBytes = PhoneRemotePairingWireCodec.maximumFrameBytes

    private let factory: any PhonePinnedConnectionFactory
    private let timeout: TimeInterval

    public init(
        factory: any PhonePinnedConnectionFactory = PhoneNWConnectionFactory(),
        timeout: TimeInterval = 5
    ) {
        self.factory = factory
        self.timeout = timeout
    }

    public func callAsFunction(
        endpoint: PhonePinnedEndpoint,
        requestFrame: Data
    ) async throws -> Data {
        guard endpoint.isValid else { throw PhonePinnedTLSExchangeError.invalidEndpoint }
        guard timeout > 0, timeout.isFinite else {
            throw PhonePinnedTLSExchangeError.invalidTimeout
        }
        try Self.validate(frame: requestFrame)
        let connection = try factory.makeConnection(to: endpoint)
        defer { connection.cancel() }
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await connection.start()
                    try Task.checkCancellation()
                    try await connection.send(requestFrame)
                    return try await Self.receiveFrame(from: connection)
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw PhonePinnedTLSExchangeError.timedOut
            }
            guard let result = try await group.next() else {
                throw PhonePinnedTLSExchangeError.connectionClosed
            }
            group.cancelAll()
            return result
        }
    }

    private static func receiveFrame(
        from connection: any PhonePinnedConnection
    ) async throws -> Data {
        let header = try await receiveExactly(4, from: connection)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw PhonePinnedTLSExchangeError.invalidFrame }
        guard length <= UInt32(maximumFrameBytes) else {
            throw PhonePinnedTLSExchangeError.oversizedFrame
        }
        let body = try await receiveExactly(Int(length), from: connection)
        return header + body
    }

    private static func receiveExactly(
        _ count: Int,
        from connection: any PhonePinnedConnection
    ) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await connection.receive(maximumLength: remaining)
            guard !chunk.data.isEmpty else {
                throw PhonePinnedTLSExchangeError.connectionClosed
            }
            guard chunk.data.count <= remaining else {
                throw PhonePinnedTLSExchangeError.invalidFrame
            }
            result.append(chunk.data)
            if chunk.isComplete, result.count < count {
                throw PhonePinnedTLSExchangeError.connectionClosed
            }
        }
        return result
    }

    private static func validate(frame: Data) throws {
        guard frame.count >= 4 else { throw PhonePinnedTLSExchangeError.invalidFrame }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw PhonePinnedTLSExchangeError.invalidFrame }
        guard length <= UInt32(maximumFrameBytes) else {
            throw PhonePinnedTLSExchangeError.oversizedFrame
        }
        guard frame.count == 4 + Int(length) else {
            throw PhonePinnedTLSExchangeError.invalidFrame
        }
    }
}

public struct PhoneNWConnectionFactory: PhonePinnedConnectionFactory, Sendable {
    public init() {}

    public func makeConnection(
        to endpoint: PhonePinnedEndpoint
    ) throws -> any PhonePinnedConnection {
        guard endpoint.isValid,
              let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw PhonePinnedTLSExchangeError.invalidEndpoint
        }
        let verifyQueue = DispatchQueue(label: "com.moni.codexguardian.phone.tls-verify")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        let expectedPin = endpoint.tlsCertificateHash
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let leaf = chain.first else {
                    complete(false)
                    return
                }
                let certificateDER = SecCertificateCopyData(leaf) as Data
                complete(PhoneCertificatePin.matches(
                    leafCertificateDER: certificateDER,
                    expectedSHA256: expectedPin
                ))
            },
            verifyQueue
        )
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        let queue = DispatchQueue(label: "com.moni.codexguardian.phone.connection")
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: parameters
        )
        return PhoneNWConnection(connection: connection, queue: queue)
    }
}

private final class PhoneNWConnection: PhonePinnedConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let gate = PhoneConnectionReadyGate(continuation: continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume()
                    case let .waiting(error), let .failed(error):
                        gate.resume(throwing: error)
                    case .cancelled:
                        gate.resume(throwing: PhonePinnedTLSExchangeError.connectionClosed)
                    case .setup, .preparing:
                        break
                    @unknown default:
                        gate.resume(throwing: PhonePinnedTLSExchangeError.connectionClosed)
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(maximumLength: Int) async throws -> PhonePinnedConnectionChunk {
        guard maximumLength > 0 else { throw PhonePinnedTLSExchangeError.invalidFrame }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<PhonePinnedConnectionChunk, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: .init(
                        data: content,
                        isComplete: isComplete
                    ))
                } else {
                    continuation.resume(throwing: PhonePinnedTLSExchangeError.connectionClosed)
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private final class PhoneConnectionReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        take()?.resume()
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
