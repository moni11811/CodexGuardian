import Darwin
import Foundation
import GuardianCore

enum GuardianDaemonServerError: Error {
    case invalidConfiguration
    case systemCall(String, Int32)
    case noLaunchdSocket(Int32)
    case invalidRequest
    case unauthorizedPeer
}

final class GuardianDaemonServer: @unchecked Sendable {
    private let listeningDescriptor: Int32
    private let runtime: GuardianDaemonRuntime
    private let runOnce: Bool
    private let connectionTimeout: TimeInterval

    init(
        listeningDescriptor: Int32,
        runtime: GuardianDaemonRuntime,
        runOnce: Bool,
        connectionTimeout: TimeInterval = 5
    ) {
        self.listeningDescriptor = listeningDescriptor
        self.runtime = runtime
        self.runOnce = runOnce
        self.connectionTimeout = connectionTimeout
    }

    func run() throws {
        while true {
            let client = Darwin.accept(listeningDescriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                throw GuardianDaemonServerError.systemCall("accept", errno)
            }
            do {
                defer { Darwin.close(client) }
                try GuardianSocketIO.configure(
                    descriptor: client,
                    deadline: Date().addingTimeInterval(connectionTimeout)
                )
                let verifiedPeer = try verifyPeer(client)
                let request = try readRequest(from: client)
                let reply = handleSynchronously(
                    request,
                    verifiedPeer: verifiedPeer,
                    deadline: min(
                        request.command.deadline,
                        Date().addingTimeInterval(connectionTimeout)
                    )
                )
                try writeReply(reply, to: client)
            } catch {
                if runOnce { throw error }
                continue
            }
            if runOnce { return }
        }
    }

    private func verifyPeer(_ descriptor: Int32) throws -> GuardianVerifiedLocalPeer {
        var effectiveUser = uid_t()
        var effectiveGroup = gid_t()
        guard getpeereid(descriptor, &effectiveUser, &effectiveGroup) == 0,
              effectiveUser == getuid() else {
            throw GuardianDaemonServerError.unauthorizedPeer
        }
        do {
            return try GuardianLocalPeerAttestor().inspect(descriptor: descriptor)
        } catch {
            throw GuardianDaemonServerError.unauthorizedPeer
        }
    }

    private func readRequest(from descriptor: Int32) throws -> GuardianDaemonRequest {
        let header = try GuardianSocketIO.readExactly(4, from: descriptor)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0,
              length <= UInt32(GuardianIPCFrameCodec.defaultMaximumBytes) else {
            throw GuardianDaemonServerError.invalidRequest
        }
        let payload = try GuardianSocketIO.readExactly(Int(length), from: descriptor)
        return try JSONDecoder().decode(GuardianDaemonRequest.self, from: payload)
    }

    private func handleSynchronously(
        _ request: GuardianDaemonRequest,
        verifiedPeer: GuardianVerifiedLocalPeer,
        deadline: Date
    ) -> GuardianDaemonReply {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedReplyBox()
        Task {
            box.store(await runtime.handle(request, verifiedPeer: verifiedPeer))
            semaphore.signal()
        }
        guard deadline > Date(),
              semaphore.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .success else {
            return .rejected(.storageUnavailable)
        }
        return box.load() ?? .rejected(.storageUnavailable)
    }

    private func writeReply(_ reply: GuardianDaemonReply, to descriptor: Int32) throws {
        let payload = try JSONEncoder().encode(reply)
        try GuardianSocketIO.writeAll(GuardianIPCFrameCodec.encode(payload), to: descriptor)
    }
}

private final class LockedReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GuardianDaemonReply?

    func store(_ value: GuardianDaemonReply) {
        lock.withLock { self.value = value }
    }

    func load() -> GuardianDaemonReply? {
        lock.withLock { value }
    }
}
