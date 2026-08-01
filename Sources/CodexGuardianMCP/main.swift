import Foundation
import GuardianClient
import GuardianCore

private let store = RestartRequestStore()
private let originResolver = ThreadOriginResolver()
private let automationVerifier = CodexRecoveryAutomationVerifier()

private enum GuardianDaemonStatusError: Error { case unavailable }

private final class GuardianDaemonReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: Result<GuardianDaemonReply, Error>?

    func store(_ result: Result<GuardianDaemonReply, Error>) {
        lock.withLock { reply = result }
    }

    func load() -> Result<GuardianDaemonReply, Error>? {
        lock.withLock { reply }
    }
}

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

private func daemonStatusPayload() throws -> [String: Any] {
    let stateDirectory: URL
    if let override = ProcessInfo.processInfo.environment["CODEX_GUARDIAN_DAEMON_STATE_DIR"] {
        stateDirectory = URL(fileURLWithPath: override, isDirectory: true)
    } else {
        stateDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "CodexGuardian", directoryHint: .isDirectory)
    }
    let credential = try GuardianCredentialFile.load(
        at: stateDirectory.appending(path: "credentials/mcp.token")
    )
    let client = GuardianClient(
        clientID: GuardianLocalClientDefaults.mcpID,
        credential: credential,
        transport: GuardianUnixSocketTransport(
            socketPath: stateDirectory.appending(path: "guardian.sock").path,
            expectedPeerExecutablePath: try GuardianLocalDaemonEndpoint.expectedExecutablePath()
        )
    )
    let deadline = Date().addingTimeInterval(5)
    let command = GuardianIPCCommand(
        protocolVersion: .current,
        rpcID: UUID(),
        operationID: UUID(),
        clientID: GuardianLocalClientDefaults.mcpID,
        expectedGeneration: 0,
        deadline: deadline,
        originThreadID: "codex-guardian-mcp",
        targetThreadID: "codex-guardian-mcp",
        action: .observe,
        force: false
    )
    let semaphore = DispatchSemaphore(value: 0)
    let box = GuardianDaemonReplyBox()
    Task {
        do {
            box.store(.success(try await client.send(command)))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 6) == .success,
          let result = box.load() else {
        throw GuardianDaemonStatusError.unavailable
    }
    switch try result.get() {
    case let .snapshot(snapshot):
        return [
            "state": "connected",
            "authority": "shadow_only",
            "generation": snapshot.generation,
            "last_sequence": snapshot.lastSequence,
            "operation_count": snapshot.operations.count,
        ]
    case .accepted, .rejected:
        throw GuardianDaemonStatusError.unavailable
    }
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

private func hardRecoveryHeartbeatPrompt(originToken: String) -> String {
    """
    Codex Guardian hard-recovery heartbeat \(originToken). Call the Codex Guardian recovery_tick tool with this origin_token. If state is waiting, end this run. If state is continue, follow recovery_prompt in this exact task. After meaningful progress, delete the heartbeat whose automation_id is returned, then call ack_recovery with the same origin_token.
    """
}

private func hardRecoveryPreparationPayload(
    threadID: String,
    originToken: String
) -> [String: Any] {
    [
        "thread_id": threadID,
        "origin_token": originToken,
        "heartbeat_prompt": hardRecoveryHeartbeatPrompt(originToken: originToken),
        "heartbeat_interval_minutes": 1,
        "restarts_desktop": false,
        "next_action": "Create an ACTIVE Codex heartbeat for thread_id using heartbeat_prompt and a one-minute interval. Then call restart_codex with origin_token and the returned automation id.",
    ]
}

private func toolResult(id: Any, payload: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    result(id: id, value: [
        "content": [[
            "type": "text",
            "text": String(decoding: data, as: UTF8.self),
        ]],
        "structuredContent": payload,
        "isError": false,
    ])
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
            "serverInfo": ["name": "codex-guardian", "version": "0.5.0"],
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
                "name": "guardian_status",
                "description": "Read the durable Guardian daemon generation and shadow operation count. This never restarts Codex.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "recover_agent",
                "description": "Queue automatic exact-task recovery through the always-on Guardian app. Guardian first uses an idempotent native app-server continuation without restarting Desktop. No heartbeat automation or manual Send step is required.",
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
                        "state": ["type": "string", "const": "queued_native"],
                        "request_id": ["type": "string"],
                        "thread_id": ["type": "string"],
                        "restarts_desktop": ["type": "boolean", "const": false],
                        "next_action": ["type": "string"],
                    ],
                    "required": [
                        "state",
                        "request_id",
                        "thread_id",
                        "restarts_desktop",
                        "next_action",
                    ],
                    "additionalProperties": false,
                ],
            ],
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
                "name": "prepare_restart",
                "description": "Prepare automatic exact-task continuation before a hard restart. Create the returned Codex heartbeat first; restart_codex fails closed without it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recovery_prompt": fallbackPrompt,
                        "origin_token": originToken,
                    ],
                    "required": ["origin_token"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "restart_codex",
                "description": "Queue a hard Codex restart only after prepare_restart and an exact-task Codex heartbeat. Guardian verifies the heartbeat, waits until every unrelated observed task is idle and Codex is quiet, then restarts. Only the verified recovery-heartbeat turn is ignored; resumed real work blocks restart. The heartbeat continues the exact task after relaunch.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recovery_prompt": [
                            "type": "string",
                            "description": "Optional fallback instructions. Guardian uses the local Apple model to improve them from sanitized recent task state.",
                        ],
                        "origin_token": originToken,
                        "continuation_automation_id": [
                            "type": "string",
                            "description": "Automation id returned by the ACTIVE exact-task Codex heartbeat created from prepare_restart.",
                        ],
                        "delay_seconds": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 30,
                            "default": 2,
                        ],
                    ],
                    "required": ["origin_token", "continuation_automation_id"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "recovery_tick",
                "description": "Heartbeat check for an armed hard recovery. Returns waiting before relaunch or the exact recovery prompt after relaunch.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["origin_token": originToken],
                    "required": ["origin_token"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "ack_recovery",
                "description": "Acknowledge that the exact task is moving again after meaningful recovered progress. Native recovery has no heartbeat automation to delete. For hard recovery, delete the returned heartbeat automation first.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["origin_token": originToken],
                    "required": ["origin_token"],
                    "additionalProperties": false,
                ],
            ],
        ]])

    case "tools/call":
        guard let params = message["params"] as? [String: Any],
              let toolName = params["name"] as? String,
              [
                "guardian_status",
                "recover_agent",
                "prepare_recovery",
                "prepare_restart",
                "restart_codex",
                "recovery_tick",
                "ack_recovery",
              ].contains(toolName) else {
            writeError(id: id, code: -32602, message: "Unknown tool")
            return
        }
        if toolName == "guardian_status" {
            do {
                try toolResult(id: id, payload: daemonStatusPayload())
            } catch {
                writeError(
                    id: id,
                    code: -32603,
                    message: "Guardian daemon is unavailable or untrusted."
                )
            }
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let originToken = arguments["origin_token"] as? String,
              UUID(uuidString: originToken) != nil else {
            writeError(id: id, code: -32602, message: "origin_token is required")
            return
        }
        do {
            switch toolName {
            case "recover_agent":
                let origin = try resolveOrigin(originToken)
                let fallbackPrompt = recoveryPrompt(
                    from: arguments,
                    originToken: originToken
                )
                let request = RestartRequest(
                    threadID: origin.threadID,
                    recoveryPrompt: fallbackPrompt,
                    contextSnapshot: origin.contextSnapshot,
                    originToken: originToken,
                    requestMode: .nativeFirst
                )
                let requestID = try store.enqueueUnique(request)
                launchGuardianIfNeeded()
                try toolResult(id: id, payload: [
                    "state": "queued_native",
                    "request_id": requestID.uuidString,
                    "thread_id": origin.threadID,
                    "restarts_desktop": false,
                    "next_action": "End this turn. Guardian now owns one idempotent exact-task continuation; do not queue another recovery with a new token.",
                ])

            case "prepare_recovery":
                let origin = try resolveOrigin(originToken)
                let fallbackPrompt = recoveryPrompt(from: arguments, originToken: originToken)
                let plan = NativeRecoveryPlan(
                    threadID: origin.threadID,
                    recoveryPrompt: fallbackPrompt
                )
                try toolResult(id: id, payload: nativeRecoveryPayload(plan))

            case "prepare_restart":
                let origin = try resolveOrigin(originToken)
                try toolResult(
                    id: id,
                    payload: hardRecoveryPreparationPayload(
                        threadID: origin.threadID,
                        originToken: originToken
                    )
                )

            case "restart_codex":
                let origin = try resolveOrigin(originToken)
                guard let automationID = arguments["continuation_automation_id"] as? String,
                      try automationVerifier.isArmed(
                        automationID: automationID,
                        threadID: origin.threadID,
                        originToken: originToken
                      ) else {
                    writeError(
                        id: id,
                        code: -32602,
                        message: "Exact-task recovery heartbeat is not durably armed; Codex was not queued for restart."
                    )
                    return
                }
                let fallbackPrompt = recoveryPrompt(from: arguments, originToken: originToken)
                let delay = arguments["delay_seconds"] as? Int ?? 2
                let request = RestartRequest(
                    threadID: origin.threadID,
                    recoveryPrompt: fallbackPrompt,
                    contextSnapshot: origin.contextSnapshot,
                    delaySeconds: delay,
                    originToken: originToken,
                    continuationAutomationID: automationID
                )
                let requestID = try store.enqueueUnique(request)
                launchGuardianIfNeeded()
                try toolResult(id: id, payload: [
                    "state": "queued",
                    "request_id": requestID.uuidString,
                    "thread_id": origin.threadID,
                    "automation_id": automationID,
                    "next_action": "End this turn. Guardian waits for unrelated tasks and the quiet period. The native heartbeat continues this exact task after relaunch.",
                ])

            case "recovery_tick":
                guard let request = try store.request(originToken: originToken) else {
                    try toolResult(id: id, payload: [
                        "state": "waiting",
                        "reason": "restart_not_armed_yet",
                    ])
                    return
                }
                if request.recoveryPhase == .queued {
                    _ = try store.markHeartbeatObserved(originToken: originToken)
                    try toolResult(id: id, payload: [
                        "state": "waiting",
                        "thread_id": request.threadID,
                        "reason": "heartbeat_registered; desktop_restart_not_complete",
                    ])
                    return
                }
                let lease = try store.leaseContinuation(originToken: originToken)
                guard let delivery = lease.request else {
                    try toolResult(id: id, payload: [
                        "state": "waiting",
                        "thread_id": request.threadID,
                        "reason": request.recoveryPhase == .deliveringContinuation
                            ? "continuation_delivery_already_running"
                            : "desktop_restart_not_complete",
                    ])
                    return
                }
                try toolResult(id: id, payload: [
                    "state": "continue",
                    "thread_id": delivery.threadID,
                    "recovery_prompt": delivery.recoveryPrompt,
                    "automation_id": delivery.continuationAutomationID ?? "",
                    "next_action": "Continue now in this exact task. After meaningful progress, delete automation_id, then call ack_recovery with origin_token.",
                ])

            case "ack_recovery":
                do {
                    let acknowledgement = try GuardianNativeRecoveryAcknowledger(
                        journal: GuardianJournal(
                            databaseURL: store.directory.appending(
                                path: "guardian.sqlite"
                            )
                        ),
                        store: store
                    ).acknowledge(originToken: originToken)
                    try toolResult(id: id, payload: [
                        "state": "acknowledged",
                        "mode": "native",
                        "operation_id": acknowledgement.operationID.uuidString,
                        "thread_id": acknowledgement.threadID,
                        "turn_id": acknowledgement.turnID,
                        "message_item_id": acknowledgement.messageItemID,
                        "already_acknowledged": acknowledgement.alreadyAcknowledged,
                    ])
                    return
                } catch GuardianNativeRecoveryAcknowledgementError.requestNotFound {
                    // No native operation owns this origin. Preserve legacy heartbeat ACK.
                }
                guard let delivered = try store.request(originToken: originToken),
                      let automationID = delivered.continuationAutomationID else {
                    writeError(id: id, code: -32602, message: "Recovery request was not found.")
                    return
                }
                if try automationVerifier.automationExists(automationID: automationID) {
                    writeError(
                        id: id,
                        code: -32602,
                        message: "Delete the recovery heartbeat before acknowledgement."
                    )
                    return
                }
                guard let requestID = try store.acknowledgeContinuation(
                    originToken: originToken
                ) else {
                    writeError(
                        id: id,
                        code: -32602,
                        message: "No delivered hard recovery is awaiting acknowledgement."
                    )
                    return
                }
                try toolResult(id: id, payload: [
                    "state": "acknowledged",
                    "request_id": requestID.uuidString,
                    "automation_id": automationID,
                ])

            default:
                writeError(id: id, code: -32602, message: "Unknown tool")
            }
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
