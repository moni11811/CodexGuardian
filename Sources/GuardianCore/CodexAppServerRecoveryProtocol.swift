import Foundation

public enum CodexAppServerRecoveryProtocolError: Error, Equatable, Sendable {
    case invalidInput
    case invalidJSON
    case invalidResponse
    case mismatchedRequestID
    case responseError(code: Int, message: String)
}

public enum CodexAppServerRecoverySubmission: Equatable, Sendable {
    case missing
    case alreadySubmitted(CodexAppServerRecoveryDelivery)
}

public struct CodexAppServerRecoveryDelivery: Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let clientMessageID: String
    public let userMessageItemID: String

    public init(
        threadID: String,
        turnID: String,
        clientMessageID: String,
        userMessageItemID: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.clientMessageID = clientMessageID
        self.userMessageItemID = userMessageItemID
    }
}

public enum CodexAppServerRecoveryCompletion: String, Equatable, Sendable {
    case completed
    case interrupted
    case failed
}

/// JSON-RPC messages and correlation checks for exact-thread recovery.
/// Socket ownership stays outside this type.
public enum CodexAppServerRecoveryProtocol {
    public static func clientMessageID(
        originToken: UUID,
        generation: UInt64
    ) -> String {
        "guardian:\(originToken.uuidString.lowercased()):\(generation)"
    }

    public static func initializeRequest(id: Int) throws -> Data {
        try encode([
            "method": "initialize",
            "id": id,
            "params": [
                "clientInfo": [
                    "name": "codex_guardian",
                    "title": "Codex Guardian",
                    "version": "0.5.0",
                ],
            ],
        ])
    }

    public static func initializedNotification() throws -> Data {
        try encode([
            "method": "initialized",
            "params": [:],
        ])
    }

    public static func resumeThreadRequest(
        id: Int,
        threadID: String
    ) throws -> Data {
        try requireNonempty(threadID)
        return try encode([
            "method": "thread/resume",
            "id": id,
            "params": ["threadId": threadID],
        ])
    }

    public static func readThreadRequest(
        id: Int,
        threadID: String
    ) throws -> Data {
        try requireNonempty(threadID)
        return try encode([
            "method": "thread/read",
            "id": id,
            "params": [
                "threadId": threadID,
                "includeTurns": true,
            ],
        ])
    }

    public static func startRecoveryTurnRequest(
        id: Int,
        threadID: String,
        prompt: String,
        clientMessageID: String
    ) throws -> Data {
        try requireNonempty(threadID)
        try requireNonempty(prompt)
        try requireNonempty(clientMessageID)
        return try encode([
            "method": "turn/start",
            "id": id,
            "params": [
                "threadId": threadID,
                "clientUserMessageId": clientMessageID,
                "input": [[
                    "type": "text",
                    "text": prompt,
                ]],
            ],
        ])
    }

    public static func resumedThreadID(
        response: Data,
        expectedRequestID: Int
    ) throws -> String {
        let object = try responseObject(response, expectedRequestID: expectedRequestID)
        guard let result = object["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String,
              !threadID.isEmpty else {
            throw CodexAppServerRecoveryProtocolError.invalidResponse
        }
        return threadID
    }

    public static func validateResponse(
        _ response: Data,
        expectedRequestID: Int
    ) throws {
        _ = try responseObject(response, expectedRequestID: expectedRequestID)
    }

    public static func startedTurnID(
        response: Data,
        expectedRequestID: Int
    ) throws -> String {
        let object = try responseObject(response, expectedRequestID: expectedRequestID)
        guard let result = object["result"] as? [String: Any],
              let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String,
              !turnID.isEmpty else {
            throw CodexAppServerRecoveryProtocolError.invalidResponse
        }
        return turnID
    }

    /// Checks persisted user-message client ids before sending a recovery turn.
    /// A retry must call this again after any ambiguous transport failure.
    public static func submission(
        inThreadReadResponse response: Data,
        expectedRequestID: Int,
        expectedThreadID: String,
        clientMessageID: String
    ) throws -> CodexAppServerRecoverySubmission {
        try requireNonempty(expectedThreadID)
        try requireNonempty(clientMessageID)
        let matches = try deliveries(
            inThreadReadResponse: response,
            expectedRequestID: expectedRequestID,
            expectedThreadID: expectedThreadID,
            clientMessageID: clientMessageID
        )
        guard matches.count <= 1 else {
            throw CodexAppServerRecoveryProtocolError.invalidResponse
        }
        guard let delivery = matches.first else { return .missing }
        return .alreadySubmitted(delivery)
    }

    public static func delivery(
        inThreadReadResponse response: Data,
        expectedRequestID: Int,
        expectedThreadID: String,
        expectedTurnID: String,
        clientMessageID: String
    ) throws -> CodexAppServerRecoveryDelivery {
        try requireNonempty(expectedTurnID)
        let matches = try deliveries(
            inThreadReadResponse: response,
            expectedRequestID: expectedRequestID,
            expectedThreadID: expectedThreadID,
            clientMessageID: clientMessageID
        ).filter { $0.turnID == expectedTurnID }
        guard matches.count == 1, let delivery = matches.first else {
            throw CodexAppServerRecoveryProtocolError.invalidResponse
        }
        return delivery
    }

    private static func deliveries(
        inThreadReadResponse response: Data,
        expectedRequestID: Int,
        expectedThreadID: String,
        clientMessageID: String
    ) throws -> [CodexAppServerRecoveryDelivery] {
        try requireNonempty(expectedThreadID)
        try requireNonempty(clientMessageID)
        let object = try responseObject(response, expectedRequestID: expectedRequestID)
        guard let result = object["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              thread["id"] as? String == expectedThreadID,
              let turns = thread["turns"] as? [[String: Any]] else {
            throw CodexAppServerRecoveryProtocolError.invalidResponse
        }

        var deliveries: [CodexAppServerRecoveryDelivery] = []
        for turn in turns {
            guard let turnID = turn["id"] as? String,
                  !turnID.isEmpty,
                  let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items where item["type"] as? String == "userMessage"
                && item["clientId"] as? String == clientMessageID {
                guard let itemID = item["id"] as? String, !itemID.isEmpty else {
                    throw CodexAppServerRecoveryProtocolError.invalidResponse
                }
                deliveries.append(CodexAppServerRecoveryDelivery(
                    threadID: expectedThreadID,
                    turnID: turnID,
                    clientMessageID: clientMessageID,
                    userMessageItemID: itemID
                ))
            }
        }
        return deliveries
    }

    public static func completion(
        notification: Data,
        expectedThreadID: String,
        expectedTurnID: String
    ) throws -> CodexAppServerRecoveryCompletion? {
        try requireNonempty(expectedThreadID)
        try requireNonempty(expectedTurnID)
        guard let object = try JSONSerialization.jsonObject(with: notification) as? [String: Any]
        else { throw CodexAppServerRecoveryProtocolError.invalidJSON }
        guard object["method"] as? String == "turn/completed" else { return nil }
        guard let params = object["params"] as? [String: Any],
              params["threadId"] as? String == expectedThreadID,
              let turn = params["turn"] as? [String: Any],
              turn["id"] as? String == expectedTurnID else {
            return nil
        }
        guard let status = turn["status"] as? String,
              let completion = CodexAppServerRecoveryCompletion(rawValue: status) else {
            throw CodexAppServerRecoveryProtocolError.invalidResponse
        }
        return completion
    }

    private static func responseObject(
        _ data: Data,
        expectedRequestID: Int
    ) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CodexAppServerRecoveryProtocolError.invalidJSON }
        guard (object["id"] as? NSNumber)?.intValue == expectedRequestID else {
            throw CodexAppServerRecoveryProtocolError.mismatchedRequestID
        }
        if let error = object["error"] as? [String: Any] {
            throw CodexAppServerRecoveryProtocolError.responseError(
                code: (error["code"] as? NSNumber)?.intValue ?? -1,
                message: error["message"] as? String ?? "Unknown app-server error"
            )
        }
        return object
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerRecoveryProtocolError.invalidJSON
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func requireNonempty(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAppServerRecoveryProtocolError.invalidInput
        }
    }
}
