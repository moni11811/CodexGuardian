import Foundation
import GuardianCore

private let store = RestartRequestStore()
private let originResolver = ThreadOriginResolver()

private func write(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private func result(id: Any, value: [String: Any]) {
    write(["jsonrpc": "2.0", "id": id, "result": value])
}

private func writeError(id: Any, code: Int, message: String) {
    write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

private func launchGuardianIfNeeded() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", "com.moni.codexguardian"]
    try? process.run()
}

private func resolveOriginThread(_ token: String) throws -> String {
    var lastError: Error = ThreadOriginResolverError.originNotFound
    for _ in 0..<20 {
        do {
            return try originResolver.resolve(originToken: token)
        } catch {
            lastError = error
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    throw lastError
}

private func handle(_ message: [String: Any]) {
    guard let method = message["method"] as? String else { return }
    let id = message["id"] ?? NSNull()

    switch method {
    case "initialize":
        let params = message["params"] as? [String: Any]
        let requestedVersion = params?["protocolVersion"] as? String ?? "2025-06-18"
        result(id: id, value: [
            "protocolVersion": requestedVersion,
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "codex-guardian", "version": "0.1.0"],
        ])

    case "notifications/initialized":
        break

    case "ping":
        result(id: id, value: [:])

    case "tools/list":
        result(id: id, value: ["tools": [[
            "name": "restart_codex",
            "description": "Restart Codex after this call returns, then resume the exact originating task. Generate a fresh UUID for origin_token on every call. Use after a tool is genuinely stuck; do not repeat an unchanged failed method after recovery.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recovery_prompt": [
                        "type": "string",
                        "description": "Instructions sent to this exact task after restart. Include the failed tool symptom and the next fallback action.",
                    ],
                    "origin_token": [
                        "type": "string",
                        "format": "uuid",
                        "description": "Fresh UUID unique to this call. Guardian finds this token in the originating rollout and binds recovery to that exact task.",
                    ],
                    "delay_seconds": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 30,
                        "default": 2,
                    ],
                ],
                "required": ["origin_token", "recovery_prompt"],
                "additionalProperties": false,
            ],
        ]]])

    case "tools/call":
        guard let params = message["params"] as? [String: Any],
              params["name"] as? String == "restart_codex" else {
            writeError(id: id, code: -32602, message: "Unknown tool")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let originToken = arguments["origin_token"] as? String,
              let prompt = arguments["recovery_prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            writeError(id: id, code: -32602, message: "origin_token and recovery_prompt are required")
            return
        }
        let delay = arguments["delay_seconds"] as? Int ?? 2
        do {
            let threadID = try resolveOriginThread(originToken)
            let request = RestartRequest(
                threadID: threadID,
                recoveryPrompt: prompt,
                delaySeconds: delay
            )
            try store.enqueue(request)
            launchGuardianIfNeeded()
            result(id: id, value: [
                "content": [[
                    "type": "text",
                    "text": "Codex restart scheduled in \(request.delaySeconds) seconds. Exact task \(threadID) queued for automatic continuation.",
                ]],
                "isError": false,
            ])
        } catch {
            writeError(id: id, code: -32603, message: error.localizedDescription)
        }

    default:
        if !(method.hasPrefix("notifications/")) {
            writeError(id: id, code: -32601, message: "Method not found")
        }
    }
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        continue
    }
    handle(message)
}
