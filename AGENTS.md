# Codex Guardian agent instructions

Guardian is the recovery path for a genuinely stuck Codex task.

## When to recover

Use `restart_codex` when a tool call remains stuck, Codex cannot make progress, or the current runtime needs a restart. Do not use it for an ordinary code/test failure that can be corrected in the current task.

## Required behavior

1. Generate a fresh UUID that appears in the current task immediately before the MCP call.
2. Call `restart_codex` with that UUID as `origin_token`.
3. Let Guardian identify this exact task, sanitize its recent state, create a continuation prompt with the on-device Apple model, restart Codex, reopen the exact desktop task, and copy the prompt.
4. Do not ask the user to restart Codex manually when Guardian is available.
5. Do not repeat an unchanged deterministic failure after recovery. Change the hypothesis, input, tool, route, or prerequisite.

`recovery_prompt` is optional. Provide it only when a precise deterministic fallback is better than Guardian's default. Never place credentials or private user data in it.

If Guardian cannot prove the origin task, it must fail closed without restarting Codex.

Guardian must never launch `codex exec resume`; that creates a detached CLI worker, causes access prompts, and does not continue the desktop task. Do not claim automatic continuation until same-desktop-app-server messaging is verified.
