# Recovery Reliability Audit

This document records external designs reviewed, applicable failure modes, and the Guardian regression that covers each adopted lesson.

Reviewed 2026-07-26. Scope: exact-task recovery, multi-task restart timing, durable continuation, and supervisor failure containment.

## Failure theory

The repeated `Waiting for Guardian restart completion` state was not a timing problem. Guardian counted the task requesting recovery as a task that prohibited recovery. That circular dependency could never clear while its heartbeat kept the task alive.

Three nearby failure classes could turn the same symptom into a permanent loop: a corrupt queue item, two MCP processes leasing one continuation, or a paused heartbeat left attached to the task. The current patch treats all four as state-machine and ownership failures.

## Evidence table

| Source | Proven pattern | Guardian gap | Regression | Decision |
| --- | --- | --- | --- | --- |
| [Codex app-server protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) | Threads and turns have explicit status notifications and terminal outcomes. Readiness is separate from process existence. | Guardian still infers task state from JSONL tails. It also released continuation as soon as the desktop PID appeared. | `requestedStuckTaskDoesNotBlockItsOwnRecovery`; `resumedWorkInRequestedTaskBlocksRestart`; `continuationWaitsForVerifiedDesktopRelaunch`; `appServerGetsAFullSettleWindowAfterItAppears` | Exclude only the verified recovery-heartbeat turn; newly resumed work blocks. Require a new app-server process followed by 15 seconds of settling. Replace JSONL inference with app-server status when Codex exposes a stable desktop transport. |
| [OpenHands lease fix](https://github.com/OpenHands/software-agent-sdk/pull/2943) | A persisted conversation needs one writer, a lease, expiry, and stale-owner fencing. | Atomic JSON replacement did not serialize read-modify-write operations. Eight concurrent MCP callers could all own one continuation. An unbounded lock wait could then hang the MCP. | `concurrentContinuationLeaseHasExactlyOneOwner`; `abandonedStateLockFailsWithABoundedBusyError` | Add a cross-process file lock around queue transitions and continuation leasing. Bound acquisition time. Keep the existing expiring delivery lease. |
| [OpenHands persistence guide](https://docs.openhands.dev/sdk/guides/convo-persistence) | Persist recovery state before the side effect; resume from the persisted state after process death. | A malformed state file aborted every request scan. Treating every read failure as corruption could also move unknown filesystem data. | `corruptPendingRequestIsPreservedWithoutBlockingValidRecovery`; `queueIOFailureFailsClosedInsteadOfQuarantiningUnknownData` | Preserve undecodable bytes under `blocked/corrupt`; continue valid work. Filesystem and permission failures stop safely without moving unknown data. |
| [Farfield reconnect regression](https://github.com/achimala/farfield/blob/a479046dfa2f13b3942d9ec3e56f56a0b84e8bee/apps/server/test/realtime-coordinator.test.ts) and [transport](https://github.com/achimala/farfield/blob/a479046dfa2f13b3942d9ec3e56f56a0b84e8bee/packages/codex-api/src/app-server-transport.ts) | Reconnect sends a fresh full snapshot with a newer generation. Child exit rejects all pending calls. Each RPC has a deadline. | Guardian has no long-lived remote transport yet. Its process capture has a byte bound but no deadline. | Not yet covered | Required before adding the phone/remote-window layer: monotonic snapshot generation, reject in-flight work on disconnect, bounded RPC deadlines. |
| [Goose queued-message loss](https://github.com/aaif-goose/goose/issues/9042) | A queued message must remain durable until the receiving runtime acknowledges it. | Earlier copy/paste continuation removed ownership too early. | `deliveredRestartWaitsForNativeHeartbeatAcknowledgement`; MCP smoke test | Keep a claimed request through restart and delivery. Delete it only after exact-task acknowledgement. |
| [Goose headless approval hang](https://github.com/aaif-goose/goose/pull/7915) | A headless supervisor needs an explicit blocked state; an unavailable approval UI must not hang forever. | Guardian currently collapses some uncertainty into generic waiting text. | Existing fail-closed automation and scan tests | Preserve fail-closed behavior. Next status model must distinguish `working`, `waiting_for_user`, `blocked`, `idle`, and `terminal`. |
| [Codex heartbeat limit bug #19563](https://github.com/openai/codex/issues/19563) | Paused/completed target-task heartbeats can still consume recovery capacity and cause resume churn. | `ack_recovery` accepted a paused heartbeat, leaving stale task links behind. | `pausedOrWrongThreadHeartbeatFailsClosed` plus MCP contract check | A recovery heartbeat must be deleted, not paused, before acknowledgement. |
| [Temporal activity guidance](https://docs.temporal.io/activities) and [message handling](https://docs.temporal.io/handling-messages) | Recovery actions may run more than once. Side effects need idempotency and message IDs need deduplication. | Concurrent processes could race on duplicate origin tokens. | `repeatedOriginTokenIsIdempotentAndConflictFailsClosed`; queue lock tests | Origin UUID remains the idempotency key. Conflicting reuse fails closed. |
| [Kubernetes probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#types-of-probe) | Startup, readiness, and liveness answer different questions. | A successful `open` plus a PID was treated as recovery readiness. | `continuationWaitsForVerifiedDesktopRelaunch` | Desktop PID is startup only. New app-server PID plus settling is the current readiness gate. Protocol health is the desired gate. |
| [Apple launchd guidance](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) and [systemd restart controls](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html) | Supervisors need restart throttling and a circuit breaker. | Guardian launch is supervised, but repeated Codex restart failures lack a durable restart budget. | Not yet covered | Add a persisted failure counter, cooldown, and manual reset before unattended remote recovery. |

## Adopted invariants

1. Only an active heartbeat carrying the request's exact origin UUID is ignored. Real resumed work in the same task blocks restart.
2. Queue state is persisted before Codex is terminated and remains until acknowledgement.
3. One decoding-corrupt item is isolated; it cannot poison unrelated recovery. Filesystem uncertainty still fails closed.
4. One origin token has one request and one active continuation lease across processes.
5. A heartbeat is deleted before acknowledgement. Pausing is not cleanup.
6. Desktop launch is not readiness. Continuation waits for a new app server and a 15-second settle window.
7. Automation IDs cannot escape their state directory.

## Next hardening, ordered

1. Replace binary JSONL-tail activity inference with authoritative app-server thread/turn status.
2. Add a durable restart budget: bounded attempts, exponential cooldown, visible circuit-breaker state, manual reset.
3. Give every external process/RPC call a deadline; terminate owned children and reject all in-flight work on disconnect.
4. Add monotonic snapshot generations before exposing Guardian through a phone or remote GUI.
5. Run fault-injection tests for crash-between-write-and-restart, crash-before-ack, PID reuse, permission loss, disk-full, and app-server startup timeout.

## Rejected patterns

- Restarting when activity state is unknown. This can destroy unrelated work.
- Treating `open` success, a desktop PID, or a copied prompt as proof of continuation.
- Running `codex exec resume`. It creates a detached worker and can trigger new access prompts.
- Pausing the heartbeat after success. It leaves a target-task relationship behind.
- Unlimited unchanged retry. Deterministic failures require a changed route or a visible blocked state.
