# Recovery workflows

Guardian uses three routes. The route is selected by evidence, not by how long a task has been quiet.

## Current capabilities

| Capability | State | Evidence boundary |
| --- | --- | --- |
| Local daemon, SQLite journal, authenticated Unix socket | Implemented and installed | Production verifier and CLI health call |
| MCP registration and `guardian_status` | Implemented and installed | Installed MCP smoke test plus live call required after Codex restart |
| Direct exact-task native queue with `prepare_recovery` | Live-proven | Continuation arrived in the same disposable Desktop task |
| Guardian-owned `recover_agent` native operation | Implemented | Durable outbox, exact receipt, reconciliation, and ACK tests; live Desktop compatibility remains version-sensitive |
| Progress-aware state model and multi-task restart gates | Implemented | Deterministic policy, concurrency, crash, and safe-point tests |
| Unattended hard restart | Unavailable in production UI | Complete authoritative Desktop inventory/control is not proven |
| Local Force Restart | Guarded emergency path | Mac-local confirmation plus previously armed continuation required |
| Local Apple-model continuation drafting | Implemented where available | macOS 26+, bounded/redacted input; advisory only |
| iPhone pairing and observation | Experimental | Source and tests; no shipped app or live-device product claim |
| iPhone prompt/restart commands | Unavailable | Production service fails closed |

## Route 1: observe

Use `guardian_status` or the dashboard when the task may simply be slow, waiting for input, or still progressing. Observation never restarts Codex.

Guardian distinguishes:

- working/running
- waiting for user
- slow
- stuck
- recovering
- idle/finished
- unknown

Silence alone never means stuck. Quiet tools, builds, downloads, terminals, and subagents may still be healthy.

## Route 2A: direct native same-task queue

This is the preferred live route while Codex can call its own desktop tools.

```text
1. Generate fresh UUID U in the current task.
2. Call prepare_recovery(origin_token: U, recovery_prompt: optional safe text).
3. Read returned thread_id and recovery_prompt.
4. Immediately call codex_app__send_message_to_thread with those exact values.
5. End the current turn.
6. The delegated continuation arrives in the same Desktop task.
```

Properties:

- no Codex restart
- no heartbeat automation
- no Guardian operation requiring `ack_recovery`
- exact origin fails closed if the UUID cannot be found and bound
- Codex’s native desktop queue supplies the continuation

## Route 2B: Guardian-owned native recovery

`recover_agent` persists a request before delivery. The always-on app claims it, sends an idempotent client message through the bundled Codex app-server transport, records an exact task/turn/message receipt, and waits for acknowledgement.

Use one UUID once. If the MCP says the request is queued, end the turn. Do not create another UUID for the same recovery. After meaningful recovered progress, call `ack_recovery` with the original UUID. Native recovery has no heartbeat automation to delete.

If delivery is ambiguous, Guardian marks it for reconciliation. It must read an exact correlated receipt before treating the message as delivered; it does not blindly resend.

## Route 3: armed hard recovery

Hard recovery exists for a genuinely unhealthy Desktop runtime, not an ordinary tool or code failure.

Required state sequence:

```text
prepared -> gated -> restart issued -> Desktop started -> control ready
-> exact task loaded -> continuation sent -> delivery receipt -> acknowledged
```

Required operational sequence:

```text
prepare_restart -> create exact ACTIVE heartbeat -> restart_codex
-> recovery_tick(waiting, end run)
-> Desktop restart and readiness
-> recovery_tick(continue)
-> meaningful progress
-> delete heartbeat automation
-> ack_recovery
```

The hard path refuses to start without an exact active heartbeat. It waits for unrelated work and a quiet window, rechecks immediately before termination, fences process identity and authority, persists state before side effects, and leases continuation so only one heartbeat delivers it.

### Current hard-restart boundary

The production dashboard deliberately reports **Automatic restart unavailable**. Current Codex Desktop exposes a private stdio app-server but not a supported, complete external inventory/control channel. A standalone app-server is not proof of the live Desktop UI or every running task.

Guardian will not substitute UI automation or assume a PID means safety. Automatic termination remains disabled until a supported Desktop transport proves:

1. complete task and background-work inventory
2. live UI synchronization
3. exact message persistence and correlation
4. atomic final safe-point revalidation
5. post-relaunch readiness and exact-task reload

## Failure and retry rules

- Capture the exact failed action and symptom.
- Retry unchanged only when evidence says the failure was transient.
- Otherwise change one meaningful variable: hypothesis, input, route, tool, or prerequisite.
- Never build downstream features to hide a failed critical path.
- If the changed fallback also fails, preserve state and stop.
- `recovery_tick` returning `waiting` means end that heartbeat run.
- Delete, do not pause, a hard-recovery heartbeat before ACK.
- An ACK is allowed only after meaningful recovered progress.

## Multiple tasks

Requests are durable and keyed independently. One task does not overwrite another. Any unrelated task that is active, unknown, stale, or incompletely observed blocks global automatic restart. Only the exact verified recovery-heartbeat turn may be ignored, and real work resumed in that same task blocks again.
