import Foundation
import GuardianCore

public protocol GuardianClientTransport: Sendable {
    func exchange(frame: Data, deadline: Date) async throws -> Data
}

public enum GuardianClientError: Error, Equatable, Sendable {
    case clientIdentityMismatch
    case invalidReplyFrame
    case unexpectedReply
}

public struct GuardianClient: Sendable {
    public let clientID: UUID
    private let credential: Data
    private let transport: any GuardianClientTransport

    public init(
        clientID: UUID,
        credential: Data,
        transport: any GuardianClientTransport
    ) {
        self.clientID = clientID
        self.credential = credential
        self.transport = transport
    }

    public func send(_ command: GuardianIPCCommand) async throws -> GuardianDaemonReply {
        guard command.clientID == clientID else {
            throw GuardianClientError.clientIdentityMismatch
        }
        let request = GuardianDaemonRequest(
            credential: credential,
            command: command
        )
        let payload = try JSONEncoder().encode(request)
        let responseFrame = try await transport.exchange(
            frame: GuardianIPCFrameCodec.encode(payload),
            deadline: command.deadline
        )
        var decoder = GuardianIPCFrameDecoder()
        let frames = try decoder.append(responseFrame)
        guard frames.count == 1 else {
            throw GuardianClientError.invalidReplyFrame
        }
        return try JSONDecoder().decode(GuardianDaemonReply.self, from: frames[0])
    }

    public func observeSnapshot(
        originThreadID: String,
        deadline: Date
    ) async throws -> GuardianIPCFullSnapshot {
        let command = GuardianIPCCommand(
            protocolVersion: .current,
            rpcID: UUID(),
            operationID: UUID(),
            clientID: clientID,
            expectedGeneration: 0,
            deadline: deadline,
            originThreadID: originThreadID,
            targetThreadID: originThreadID,
            action: .observe,
            force: false
        )
        guard case let .snapshot(snapshot) = try await send(command) else {
            throw GuardianClientError.unexpectedReply
        }
        return snapshot
    }
}
