# Codex Guardian Three-Way Recovery Research

## User-visible outcome

Guardian detects a genuinely stuck Codex task, preserves its exact identity and checkpoint, restarts only when safe, returns to that same task, submits a continuation, and receives a positive acknowledgement.

## Proof gate

Every transition must map to a real current API or a locally controlled durable protocol. Any missing transition is named before implementation.

## Candidate loop

1. **Codex task** records heartbeat, exact task identity, checkpoint, and recovery intent through Guardian MCP.
2. **Guardian macOS app** independently supervises Codex, evaluates leases across all tasks, and performs the restart only after the safety policy passes.
3. **Codex recovery runner** is re-entered through a Codex-owned continuation surface, consumes the checkpoint in the exact task, continues work, and acknowledges completion through Guardian MCP.

## Research lanes

- Current repository capabilities and gaps.
- Current Codex-supported task, automation, and MCP surfaces.
- Comparable watchdog, lease, workflow-resume, and durable-execution designs.

## Findings

## Verdict

**Feasible enough for a direct proof. Not yet proven end to end.**

Earlier research targeted the wrong boundary. Guardian need not click Codex UI or own Desktop's private stdio. Current Codex exposes a managed app-server daemon, local Unix control socket, `thread/resume`, `turn/start`, lifecycle events, and version-generated schemas.

Missing proof: after a real restart, can Guardian resume the recorded thread, submit exactly one recovery turn, and make it appear in the same Desktop task?

## Earlier mistake

- Treated private Desktop stdio as the only control surface.
- Treated heartbeat automation as the only post-restart entry.
- Considered detached `codex exec resume`; wrong execution path.
- Missed current app-server daemon and v2 thread/turn API.
- Combined detection, restart, continuation, and acknowledgement into one waiting loop.

## Current Codex evidence

- [App-server protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md): Unix socket, `thread/list`, `thread/read`, `thread/resume`, `turn/start`, status events, `turn/completed`, and `clientUserMessageId`.
- [Managed app-server daemon](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md): serialized lifecycle, persisted settings, readiness handshake, PID and lock state.
- [Codex MCP interface](https://github.com/openai/codex/blob/main/codex-rs/docs/codex_mcp_interface.md): experimental v2 thread/turn control over MCP.
- Live Codex tools expose exact-task `send_message_to_thread` and task-bound heartbeat automation. Useful while Codex lives; insufficient alone for hard recovery.

Use the local Unix socket. Network WebSocket remains experimental.

## Correct three-actor loop

### 1. Codex task

Calls Guardian MCP: register exact thread/turn, checkpoint progress, renew lease, arm recovery, then acknowledge meaningful resumed progress.

### 2. Guardian MCP

Durable coordination plane: exact identity, checkpoints, task leases, recovery attempts, idempotency keys, and one compare-and-swap fenced generation. No UI automation. No process ownership.

### 3. Guardian macOS App

Independent supervisor and app-server client. Survives Codex exit. Watches process health plus thread events. Checks every task. Restarts only when safe. Calls `thread/resume`, then one idempotent `turn/start`. Waits for exact MCP acknowledgement.

## Three-phase handshake

1. **PREPARED:** task commits checkpoint; MCP binds `origin_token + thread_id + turn_id`; App proves a post-restart route before stopping Codex.
2. **EXECUTING:** App claims fenced generation; checks other tasks; restarts; waits for app-server readiness; resumes exact thread; starts one turn using deterministic `clientUserMessageId`.
3. **ACKNOWLEDGED:** recovered exact task calls `ack_recovery(origin_token, generation)` after real progress. MCP atomically closes the attempt.

Timeout means failure or escalation. Never success.

## Minimum durable state

```text
TaskLease: thread_id, turn_id, workspace, state, progress_digest,
last_event, lease_expiry, pending_approval, background_work, restart_safe

RecoveryAttempt: origin_token, thread_id, source_turn_id, generation,
state, checkpoint, prompt, client_user_message_id, resumed_turn_id,
acknowledged_at, failure
```

Unique: `origin_token`, `(thread_id, generation)`, `client_user_message_id`.

## Multi-task restart gate

Lease expiry only creates suspicion. Restart additionally requires unchanged progress, no recent app-server events, no pending user approval, no unknown background work, every unrelated task safe, and current fenced ownership. Unknown state fails closed. Human **Force Restart** remains.

## Comparable patterns

- [Temporal](https://docs.temporal.io/): durable history and idempotent effects.
- [Kubernetes Leases](https://kubernetes.io/docs/concepts/architecture/leases/): expiring ownership plus fencing; timeout is suspicion only.
- [systemd D-Bus/watchdog](https://www.freedesktop.org/wiki/Software/systemd/dbus/): separate liveness, readiness, result, and restart limits.
- [Erlang/OTP supervision](https://www.erlang.org/docs/27/system/design_principles.html): independent supervisor, restart strategy, intensity cap, escalation.

Combined rule: persist exact checkpoint, watchdog lease plus fenced generation, and exact-target acknowledgement.

## Smallest proof experiment

1. Verify installed Codex has managed app-server and Unix socket.
2. Generate bindings from that exact binary.
3. Create disposable thread; store its id.
4. Restart managed app-server.
5. Resume same thread id.
6. Send one recovery turn with fixed `clientUserMessageId`.
7. Prove one `turn/completed` and one matching MCP acknowledgement.
8. Relaunch Desktop; prove same task displays the new turn.
9. Add second active task; prove it blocks restart.

Only then modify the full app.

Pass: same thread, one continuation, same Desktop task visible, exact ack, no duplicate, unrelated task preserved.

If Desktop reconciliation fails, stop. Claim backend thread recovery only; name the UI gap precisely.
## Comparable-system patterns

**Temporal durable execution.** [Temporal docs](https://docs.temporal.io/) describe crash-proof workflow execution: a durable Workflow ID and event history let a worker replay deterministic workflow code after a worker, network, or infrastructure failure. Transfer: persist an immutable checkpoint/command journal before dispatch; make the resume token identify one exact run; make side effects idempotent or recorded. Limit: replay only works when workflow code is deterministic and external effects are separately fenced; it does not independently prove that a desktop task resumed or completed.

**Kubernetes Lease plus controller.** Kubernetes [Leases](https://kubernetes.io/docs/concepts/architecture/leases/) hold `holderIdentity`, `renewTime`, duration, and transition count. [Coordinated leader election](https://kubernetes.io/docs/concepts/cluster-administration/coordinated-leader-election/) uses expiration plus optimistic `resourceVersion` updates, so one standby controller takes over rather than two acting concurrently. Transfer: watchdog ownership must be an expiring, versioned lease; recovery must atomically claim the checkpoint and record an attempt/fencing generation. Limit: an expired lease only establishes a suspect actor; clock/partition assumptions remain, and it contains no workflow-level acknowledgement protocol.

**systemd watchdog/service manager.** systemd records a service's watchdog result and last watchdog timestamp through its [manager D-Bus interface](https://wiki.freedesktop.org/www/Software/systemd/dbus/); missed watchdog pings produce a `watchdog` failure result, while `start-limit` identifies restart storms. Transfer: separate liveness signals from readiness/finished acknowledgement; bound restarts, retain reason/timestamp, and escalate rather than silently loop. Limit: systemd restarts a process/service, not a semantically exact user workflow; checkpoint persistence and idempotent resume remain application work.

**Erlang/OTP supervision trees.** OTP defines workers and supervisors; supervisors monitor and restart workers ([design principles](https://www.erlang.org/docs/27/system/design_principles.html)). Its current [supervisor API](https://www.erlang.org/doc/apps/stdlib/supervisor.html) sets restart strategy and restart intensity/period, then shuts down after excess restarts. Transfer: make the watchdog an independent supervisor, declare which failures are retryable, cap repeated recovery, and escalate with the original failure evidence. Limit: supervision concerns process lifetime; dynamic child state can be lost when its supervisor restarts, so durable checkpointing and explicit completion acknowledgement are still required.

**Synthesis.** Use three durable records: (1) agent checkpoint with exact task/run token and monotonic stage, (2) watchdog lease plus claimed recovery-attempt generation, and (3) target acknowledgement matching both token and generation. Treat every handoff as at-least-once; permit resume only after a compare-and-swap claim; accept completion only from the exact target. Timeout without acknowledgement is evidence to escalate, never evidence of completed recovery.
