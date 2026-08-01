import Foundation

public protocol CodexAppServerRecoveryTransport: Sendable {
    func exchange(request: Data, deadline: Date) throws -> Data
    func send(notification: Data, deadline: Date) throws
    func receive(deadline: Date) throws -> Data
}

public enum CodexAppServerRecoveryOutcome: Equatable, Sendable {
    case alreadySubmitted(CodexAppServerRecoveryDelivery)
    case completed(CodexAppServerRecoveryDelivery)
    case interrupted(threadID: String, turnID: String)
    case failed(threadID: String, turnID: String)
}

public enum CodexAppServerRecoveryCoordinatorError: Error, Equatable, Sendable {
    case deadlineExceeded
    case resumedWrongThread(expected: String, actual: String)
}

/// Runs PREPARED -> EXECUTING -> terminal observation over one app-server connection.
/// Guardian's durable fenced generation remains the authority for retries and acknowledgement.
public struct CodexAppServerRecoveryCoordinator: Sendable {
    public init() {}

    public func recover(
        threadID: String,
        prompt: String,
        originToken: UUID,
        generation: UInt64,
        transport: any CodexAppServerRecoveryTransport,
        deadline: Date,
        livenessPolicy: CodexAppServerRecoveryLivenessPolicy = .production
    ) throws -> CodexAppServerRecoveryOutcome {
        try requireTime(deadline)
        let initializeResponse = try transport.exchange(
            request: CodexAppServerRecoveryProtocol.initializeRequest(id: 1),
            deadline: deadline
        )
        try CodexAppServerRecoveryProtocol.validateResponse(
            initializeResponse,
            expectedRequestID: 1
        )
        try transport.send(
            notification: CodexAppServerRecoveryProtocol.initializedNotification(),
            deadline: deadline
        )

        try requireTime(deadline)
        let resumeResponse = try transport.exchange(
            request: CodexAppServerRecoveryProtocol.resumeThreadRequest(
                id: 2,
                threadID: threadID
            ),
            deadline: deadline
        )
        let resumedThreadID = try CodexAppServerRecoveryProtocol.resumedThreadID(
            response: resumeResponse,
            expectedRequestID: 2
        )
        guard resumedThreadID == threadID else {
            throw CodexAppServerRecoveryCoordinatorError.resumedWrongThread(
                expected: threadID,
                actual: resumedThreadID
            )
        }

        let clientMessageID = CodexAppServerRecoveryProtocol.clientMessageID(
            originToken: originToken,
            generation: generation
        )
        try requireTime(deadline)
        let readResponse = try transport.exchange(
            request: CodexAppServerRecoveryProtocol.readThreadRequest(
                id: 3,
                threadID: threadID
            ),
            deadline: deadline
        )
        let submission = try CodexAppServerRecoveryProtocol.submission(
            inThreadReadResponse: readResponse,
            expectedRequestID: 3,
            expectedThreadID: threadID,
            clientMessageID: clientMessageID
        )
        if case .alreadySubmitted(let delivery) = submission {
            return .alreadySubmitted(delivery)
        }

        try requireTime(deadline)
        let startResponse = try transport.exchange(
            request: CodexAppServerRecoveryProtocol.startRecoveryTurnRequest(
                id: 4,
                threadID: threadID,
                prompt: prompt,
                clientMessageID: clientMessageID
            ),
            deadline: deadline
        )
        let turnID = try CodexAppServerRecoveryProtocol.startedTurnID(
            response: startResponse,
            expectedRequestID: 4
        )

        var liveness = CodexAppServerRecoveryLivenessTracker(
            policy: livenessPolicy,
            startedAt: Date(),
            hardDeadline: deadline
        )
        while liveness.deadline > Date() {
            let notification = try transport.receive(deadline: liveness.deadline)
            guard let completion = try CodexAppServerRecoveryProtocol.completion(
                notification: notification,
                expectedThreadID: threadID,
                expectedTurnID: turnID
            ) else {
                _ = try liveness.observe(
                    notification: notification,
                    expectedThreadID: threadID
                )
                continue
            }
            switch completion {
            case .completed:
                try requireTime(deadline)
                let finalReadResponse = try transport.exchange(
                    request: CodexAppServerRecoveryProtocol.readThreadRequest(
                        id: 5,
                        threadID: threadID
                    ),
                    deadline: deadline
                )
                return .completed(try CodexAppServerRecoveryProtocol.delivery(
                    inThreadReadResponse: finalReadResponse,
                    expectedRequestID: 5,
                    expectedThreadID: threadID,
                    expectedTurnID: turnID,
                    clientMessageID: clientMessageID
                ))
            case .interrupted:
                return .interrupted(threadID: threadID, turnID: turnID)
            case .failed:
                return .failed(threadID: threadID, turnID: turnID)
            }
        }
        throw CodexAppServerRecoveryCoordinatorError.deadlineExceeded
    }

    private func requireTime(_ deadline: Date) throws {
        guard deadline > Date() else {
            throw CodexAppServerRecoveryCoordinatorError.deadlineExceeded
        }
    }
}
