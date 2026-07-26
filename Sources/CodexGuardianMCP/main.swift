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

private func resolveOrigin(_ token: String) throws -> RecoveryOrigin {
    var lastError: Error = ThreadOriginResolverError.originNotFound
    for _ in 0..<20 {
        do {
            return try originResolver.resolveRecoveryOrigin(originToken: token)
        } catch {
            lastError = error
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    throw lastError
}

private func recoveryPrompt(from arguments: [String: Any], originToken: String) -> String {
    let supplied = arguments["recovery_prompt"] as? String
    let prompt = supplied?.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = (prompt?.isEmpty == false) ? prompt! : RestartRequest.defaultPrompt
    return RecoveryContextExtractor().sanitize(selected, originToken: originToken)
}

private func nativeRecoveryPayload(_ plan: NativeRecoveryPlan) -> [String: Any] {
    [
        "thread_id": plan.threadID,
        "recovery_prompt": plan.recoveryPrompt,
        "restarts_desktop": plan.restartsDesktop,
        "next_action": "Call codex_app__send_message_to_thread now with thread_id and recovery_prompt, then end the current turn.",
    ]
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
            "serverInfo": ["name": "codex-guardian", "version": "0.2.0"],
        ])

    case "notifications/initialized":
        break

    case "ping":
        result(id: id, value: [:])

    case "tools/list":
        let originToken: [String: Any] = [
            "type": "string",
            "format": "uuid",
            "description": "Fresh UUID unique to this call. Guardian finds it in the originating rollout and binds recovery to that exact desktop task.",
        ]
        let fallbackPrompt: [String: Any] = [
            "type": "string",
            "description": "Optional fallback instructions. Never include credentials or private user data.",
        ]
        result(id: id, value: ["tools": [
            [
                "name": "prepare_recovery",
                "description": "Resolve the exact originating desktop task without restarting Codex. Then call codex_app__send_message_to_thread with the returned thread_id and recovery_prompt. This is the preferred recovery path.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recovery_prompt": fallbackPrompt,
                        "origin_token": originToken,
                    ],
                    "required": ["origin_token"],
                    "additionalProperties": false,
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": [
                        "thread_id": ["type": "string"],
                        "recovery_prompt": ["type": "string"],
                        "restarts_desktop": ["type": "boolean", "const": false],
                        "next_action": ["type": "string"],
                    ],
                    "required": [
                        "thread_id",
                        "recovery_prompt",
                        "restarts_desktop",
                        "next_action",
                    ],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "restart_codex",
                "description": "Hard-restart Codex after this call returns, reopen the exact originating desktop task, and copy a recovery prompt. This cannot submit a new turn automatically. Generate a fresh UUID for origin_token on every call.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recovery_prompt": [
                            "type": "string",
                            "description": "Optional fallback instructions. Guardian uses the local Apple model to improve them from sanitized recent task state.",
                        ],
                        "origin_token": originToken,
                        "delay_seconds": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 30,
                            "default": 2,
                        ],
                    ],
                    "required": ["origin_token"],
                    "additionalProperties": false,
                ],
            ],
        ]])

    case "tools/call":
        guard let params = message["params"] as? [String: Any],
              let toolName = params["name"] as? String,
              ["prepare_recovery", "restart_codex"].contains(toolName) else {
            writeError(id: id, code: -32602, message: "Unknown tool")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let originToken = arguments["origin_token"] as? String else {
            writeError(id: id, code: -32602, message: "origin_token is required")
            return
        }
        do {
            let origin = try resolveOrigin(originToken)
            let fallbackPrompt = recoveryPrompt(from: arguments, originToken: originToken)
            if toolName == "prepare_recovery" {
                let plan = NativeRecoveryPlan(
                    threadID: origin.threadID,
                    recoveryPrompt: fallbackPrompt
                )
                let payload = nativeRecoveryPayload(plan)
                let data = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.sortedKeys]
                )
                result(id: id, value: [
                    "content": [[
                        "type": "text",
                        "text": String(decoding: data, as: UTF8.self),
                    ]],
                    "structuredContent": payload,
                    "isError": false,
                ])
                return
            }
            let delay = arguments["delay_seconds"] as? Int ?? 2
            let request = RestartRequest(
                threadID: origin.threadID,
                recoveryPrompt: fallbackPrompt,
                contextSnapshot: origin.contextSnapshot,
                delaySeconds: delay
            )
            try store.enqueue(request)
            launchGuardianIfNeeded()
            result(id: id, value: [
                "content": [[
                    "type": "text",
                    "text": "Codex restart scheduled in \(request.delaySeconds) seconds. Guardian will reopen exact task \(origin.threadID) and copy a private on-device recovery prompt. Detached CLI continuation is disabled to prevent access prompts.",
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
