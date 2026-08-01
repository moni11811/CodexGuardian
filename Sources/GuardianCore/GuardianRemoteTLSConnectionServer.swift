import Foundation
import Network

public enum GuardianRemoteTLSServerError: Error, Equatable, Sendable {
    case listenerRequired
    case alreadyStarted
}

public final class GuardianRemoteTLSConnectionServer: @unchecked Sendable {
    public typealias GenerationProvider = @Sendable () async throws -> Int64

    private enum TransportError: Error {
        case connectionClosed
        case invalidFrame
    }

    private let listener: NWListener
    private let handler: GuardianRemoteConnectionHandler
    private let generationProvider: GenerationProvider
    private let requestTimeout: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var started = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(
        listener: NWListener?,
        handler: GuardianRemoteConnectionHandler,
        requestTimeout: TimeInterval = 5,
        queue: DispatchQueue = DispatchQueue(label: "com.moni.codexguardian.remote-tls"),
        generationProvider: @escaping GenerationProvider
    ) throws {
        guard let listener,
              requestTimeout > 0,
              requestTimeout.isFinite else {
            throw GuardianRemoteTLSServerError.listenerRequired
        }
        self.listener = listener
        self.handler = handler
        self.requestTimeout = requestTimeout
        self.queue = queue
        self.generationProvider = generationProvider
    }

    public func start() throws {
        let mayStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard mayStart else { throw GuardianRemoteTLSServerError.alreadyStarted }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cancelConnections()
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    public func cancel() {
        listener.cancel()
        cancelConnections()
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        lock.withLock { connections[identifier] = connection }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        Task { [weak self] in
            defer {
                timeout.cancel()
                connection.cancel()
                if let self {
                    self.lock.withLock {
                        _ = self.connections.removeValue(forKey: identifier)
                    }
                }
            }
            guard let self,
                  let peerAddress = Self.peerAddress(from: connection.endpoint) else {
                return
            }
            do {
                let frame = try await Self.receiveFrame(from: connection)
                let generation = try await generationProvider()
                let response = try await handler.handle(
                    frame: frame,
                    peerAddress: peerAddress,
                    currentGeneration: generation
                )
                try await Self.send(response, on: connection)
            } catch {
                return
            }
        }
    }

    private func cancelConnections() {
        let active = lock.withLock { () -> [NWConnection] in
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        active.forEach { $0.cancel() }
    }

    private static func peerAddress(from endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        let value = String(describing: host)
        return value.split(separator: "%", maxSplits: 1).first.map(String.init)
    }

    private static func receiveFrame(from connection: NWConnection) async throws -> Data {
        let header = try await receiveExactly(4, from: connection)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw TransportError.invalidFrame }
        guard length <= UInt32(GuardianRemoteWireCodec.maximumFrameBytes) else {
            throw TransportError.invalidFrame
        }
        return header + (try await receiveExactly(Int(length), from: connection))
    }

    private static func receiveExactly(
        _ count: Int,
        from connection: NWConnection
    ) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: TransportError.connectionClosed)
                    } else {
                        continuation.resume(throwing: TransportError.connectionClosed)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
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
}
