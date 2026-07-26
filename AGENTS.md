# Codex Guardian agent instructions

Guardian has two recovery paths. Prefer native same-task recovery. Use a hard restart only when the desktop runtime itself must restart.

## Native same-task recovery

1. Generate a fresh UUID and place it in the current task immediately before the MCP call.
2. Call `prepare_recovery` with that UUID as `origin_token`.
3. Read its exact `thread_id` and `recovery_prompt`.
4. Immediately call `codex_app__send_message_to_thread` with those values.
5. End the current turn so the queued follow-up can continue the same desktop task.

This path does not restart Codex. It is the only path that can submit an automatic continuation through Codex's own desktop interface. If Guardian cannot prove the origin task, it must fail closed.

## Hard restart

Use `restart_codex` only when Codex cannot make progress without restarting its desktop runtime.

1. Generate a fresh UUID and place it in the current task immediately before the MCP call.
2. Call `prepare_restart` with that UUID as `origin_token`.
3. Create an ACTIVE one-minute Codex heartbeat with `codex_app__automation_update`. Use the returned `thread_id` as `targetThreadId` and `heartbeat_prompt` as its prompt.
4. Call `restart_codex` with the same `origin_token` and the returned automation id as `continuation_automation_id`.
5. End the turn. Guardian waits while any observed Codex task is active.
6. After every task is idle and Codex has been quiet for 15 seconds, Guardian restarts Codex. The heartbeat calls `recovery_tick` and continues the exact task after relaunch.

If `recovery_tick` says `waiting`, end that heartbeat run. If it says `continue`, follow `recovery_prompt`. After meaningful progress, delete or pause the returned `automation_id` with `codex_app__automation_update`, then call `ack_recovery`.

Guardian must fail closed if the exact-task heartbeat cannot be created or verified. Never restart first and promise a later continuation.

Never bypass the quiet-task gate automatically. The shield menu has an explicit **Force Restart Codex Now** button for a person to use when task state cannot be trusted.

`recovery_prompt` is optional. Provide it only when a precise deterministic fallback is better than Guardian's default. Never place credentials or private user data in it.

Do not use either path for an ordinary code/test failure. Do not repeat an unchanged deterministic failure after recovery. Change the hypothesis, input, tool, route, or prerequisite.

Guardian must never launch `codex exec resume`; that creates a detached CLI worker, causes access prompts, and does not continue the desktop task.
