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
2. Call `restart_codex` with that UUID as `origin_token`.
3. Guardian restarts Codex, reopens the exact task, and copies the recovery prompt.

A hard restart cannot submit the copied prompt. Never claim that it continued automatically.

`recovery_prompt` is optional. Provide it only when a precise deterministic fallback is better than Guardian's default. Never place credentials or private user data in it.

Do not use either path for an ordinary code/test failure. Do not repeat an unchanged deterministic failure after recovery. Change the hypothesis, input, tool, route, or prerequisite.

Guardian must never launch `codex exec resume`; that creates a detached CLI worker, causes access prompts, and does not continue the desktop task.
