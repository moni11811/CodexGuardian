import Darwin
import Foundation

@main
private enum Gate0LiveProof {
    static func main() {
        guard CommandLine.arguments.count == 4 else {
            emit(["status": "error", "reason": "usage"])
            exit(64)
        }

        let executablePath = CommandLine.arguments[1]
        let threadID = CommandLine.arguments[2]
        let markerText = CommandLine.arguments[3]

        guard executablePath.hasPrefix("/"),
              !threadID.isEmpty,
              let originToken = UUID(uuidString: markerText) else {
            emit(["status": "error", "reason": "invalid-arguments"])
            exit(64)
        }

        let prompt = """
        GUARDIAN_GATE0_MARKER \(originToken.uuidString). Reply exactly \
        GUARDIAN_GATE0_ACK \(originToken.uuidString). Do not call tools, access \
        files, or modify anything.
        """
        let tracePath = "/tmp/CodexGuardianGate0Trace-\(originToken.uuidString).jsonl"

        do {
            let baseTransport = try CodexAppServerStdioTransport(
                executableURL: URL(fileURLWithPath: executablePath)
            )
            let transport = try TracingRecoveryTransport(
                base: baseTransport,
                path: tracePath
            )
            defer { baseTransport.close() }

            let outcome = try CodexAppServerRecoveryCoordinator().recover(
                threadID: threadID,
                prompt: prompt,
                originToken: originToken,
                generation: 1,
                transport: transport,
                deadline: Date().addingTimeInterval(180)
            )

            switch outcome {
            case .alreadySubmitted(let delivery):
                emit([
                    "status": "already-submitted",
                    "thread_id": delivery.threadID,
                    "turn_id": delivery.turnID,
                    "user_message_item_id": delivery.userMessageItemID,
                    "origin_token": originToken.uuidString,
                    "trace_path": tracePath
                ])
                exit(0)
            case .completed(let delivery):
                emit([
                    "status": "completed",
                    "thread_id": delivery.threadID,
                    "turn_id": delivery.turnID,
                    "user_message_item_id": delivery.userMessageItemID,
                    "origin_token": originToken.uuidString,
                    "trace_path": tracePath
                ])
                exit(0)
            case .interrupted(let recoveredThreadID, let turnID):
                emit([
                    "status": "interrupted",
                    "thread_id": recoveredThreadID,
                    "turn_id": turnID,
                    "origin_token": originToken.uuidString,
                    "trace_path": tracePath
                ])
                exit(1)
            case .failed(let recoveredThreadID, let turnID):
                emit([
                    "status": "failed",
                    "thread_id": recoveredThreadID,
                    "turn_id": turnID,
                    "origin_token": originToken.uuidString,
                    "trace_path": tracePath
                ])
                exit(1)
            }
        } catch {
            emit([
                "status": "error",
                "reason": String(describing: error),
                "origin_token": originToken.uuidString,
                "trace_path": tracePath
            ])
            exit(1)
        }
    }

    private static func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }
}

private final class TracingRecoveryTransport: @unchecked Sendable,
    CodexAppServerRecoveryTransport {
    private let base: CodexAppServerStdioTransport
    private let handle: FileHandle

    init(base: CodexAppServerStdioTransport, path: String) throws {
        self.base = base
        FileManager.default.createFile(atPath: path, contents: Data())
        self.handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    deinit {
        try? handle.close()
    }

    func exchange(request: Data, deadline: Date) throws -> Data {
        trace(direction: "send", data: request)
        let response = try base.exchange(request: request, deadline: deadline)
        trace(direction: "receive", data: response)
        return response
    }

    func send(notification: Data, deadline: Date) throws {
        trace(direction: "send", data: notification)
        try base.send(notification: notification, deadline: deadline)
    }

    func receive(deadline: Date) throws -> Data {
        let message = try base.receive(deadline: deadline)
        trace(direction: "receive", data: message)
        return message
    }

    private func trace(direction: String, data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return }
        var summary: [String: Any] = ["direction": direction]
        if let method = object["method"] as? String {
            summary["method"] = method
        }
        if let id = object["id"] as? NSNumber {
            summary["id"] = id
        }
        if object["result"] != nil { summary["kind"] = "result" }
        if let error = object["error"] as? [String: Any] {
            summary["kind"] = "error"
            summary["error_code"] = error["code"] ?? NSNull()
        }
        summarizeContainer(object["params"], prefix: "params", into: &summary)
        summarizeContainer(object["result"], prefix: "result", into: &summary)
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: summary,
            options: [.sortedKeys]
        ) else { return }
        try? handle.write(contentsOf: encoded + Data([0x0A]))
    }

    private func summarizeContainer(
        _ value: Any?,
        prefix: String,
        into summary: inout [String: Any]
    ) {
        guard let container = value as? [String: Any] else { return }
        summary["\(prefix)_keys"] = container.keys.sorted()
        if let threadID = container["threadId"] as? String {
            summary["thread_id"] = threadID
        }
        if let thread = container["thread"] as? [String: Any] {
            summary["thread_id"] = thread["id"] ?? NSNull()
            summary["thread_status"] = thread["status"] ?? NSNull()
        }
        if let turn = container["turn"] as? [String: Any] {
            summary["turn_id"] = turn["id"] ?? NSNull()
            summary["turn_status"] = turn["status"] ?? NSNull()
        }
    }
}
