# Codex Guardian agent instructions

Guardian has two recovery paths. Prefer native same-task recovery. Use a hard restart only when the desktop runtime itself must restart.

## Outcome-first execution guard

Before substantial work, state one user-visible outcome and the direct evidence
that would prove it. Keep that outcome separate from supporting artifacts.

Status must lead with whether the requested user-visible outcome works now.
Tests and documentation follow it; they never replace it.

Research, scaffolding, test counts, and documentation are not the deliverable unless the user requested them.
Do not describe them as successful delivery while the critical user flow is
unproven or failing.

After a feasibility gate fails, stop downstream implementation.
Perform at most one changed, evidence-backed fallback. If it also fails, preserve
work, state the exact missing capability, and stop. Never build later phases to
create the appearance of progress.

After three bounded tool or research rounds without movement toward the user-visible outcome, stop and re-evaluate the route.
The next action must change the hypothesis or directly test the critical path.
Automatic goal continuation does not waive this stop-loss.

Use the standard Codex or Claude permission system. ClosedDexter adds no custom
allow/deny dialogs, PreToolUse permission broker, or mandatory task ledger.

A proof-lane failure does not block an independent direct outcome. It limits
only that proof or release claim; repair the lane separately.

If a goal is blocked by a required external capability, do only novel,
bounded unblock checks. Do not spend the blocked interval on downstream scope.
Report the smallest external change that would unblock the real outcome.

Before ending substantial work, answer these questions plainly:

1. Does the user-visible flow work now?
2. What direct live evidence proves it?
3. If it does not work, why did work stop here?
4. Did any external mutation occur, and where was it explicitly authorized?

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
6. After every unrelated task is idle and Codex has been quiet for 15 seconds, Guardian restarts Codex. Only the verified recovery-heartbeat turn is ignored; newly resumed real work in that task blocks restart. The heartbeat calls `recovery_tick` and continues the exact task after relaunch.

If `recovery_tick` says `waiting`, end that heartbeat run. If it says `continue`, follow `recovery_prompt`. After meaningful progress, delete the returned `automation_id` with `codex_app__automation_update`, then call `ack_recovery`. Pausing is insufficient because paused target-task heartbeats can still consume Codex recovery capacity.

Guardian must fail closed if the exact-task heartbeat cannot be created or verified. Never restart first and promise a later continuation.

Never bypass the quiet-task gate automatically. The shield menu has an explicit **Force Restart Codex Now** button for a person to use when task state cannot be trusted.

`recovery_prompt` is optional. Provide it only when a precise deterministic fallback is better than Guardian's default. Never place credentials or private user data in it.

Do not use either path for an ordinary code/test failure. Do not repeat an unchanged deterministic failure after recovery. Change the hypothesis, input, tool, route, or prerequisite.

Guardian must never launch `codex exec resume`; that creates a detached CLI worker, causes access prompts, and does not continue the desktop task.
