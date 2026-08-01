# Phase 8 durable remote command execution design

Status: design only. No remote release authorization.

## Bug theory

The current gateway durably authenticates a command, stores its signed header and
receipt, and creates a `pending` outcome. It discards the packet payload. No
daemon-owned executor, claim lease, adapter idempotency contract, or terminal
transition exists. After acceptance, a crash can therefore leave work pending
forever; adding a direct adapter call would instead risk applying the same side
effect twice after an ambiguous disconnect.

Acceptance must mean only **durably queued**. Applied must mean a named semantic
effect was proved. Unknown must never be presented as success or blindly retried.

## Invariants

1. One transaction stores command, receipt, pending outcome, encrypted payload,
   queue row, device sequence, replay nonce, and acceptance audit before success
   is returned.
2. No plaintext payload, signature, nonce, approval answer, prompt, path, or
   terminal content enters SQLite metadata, logs, audit reasons, or metrics.
3. One renewable generation-fenced lease owns a command. A stale owner cannot
   authorize an effect or write its outcome.
4. A side effect receives `commandID` as its stable idempotency key. An adapter
   without authoritative idempotency or reconciliation is not remotely exposed.
5. Before each effect, the daemon atomically rechecks device revocation,
   capability, deadline, policy epoch, authority epoch, target identity, and
   required fresh evidence.
6. A crash after durable effect intent always enters reconciliation. It never
   assumes the effect did or did not happen.
7. Terminal outcomes are immutable and monotonic. One outcome transition and its
   daemon event commit in the same SQLite transaction.
8. A queued command from an old daemon generation is not newly applied. A prior
   ambiguous attempt may only be reconciled under the new generation.
9. Remote `force` remains forbidden. Hard recovery still uses Guardian's safe
   point, budgets, circuits, authority fence, and exact-task operation engine.
10. Remote stays disabled until the security and live-network exit evidence at
    the end of this document exists.

## State model

```text
authenticated
  -> queued
  -> claimed
  -> effectPrepared
  -> applied | failed | indeterminate

claimed --lease expires before effectPrepared--> queued
effectPrepared --crash/timeout--> reconciling
reconciling -> applied | failed | indeterminate
reconciling --authoritative notApplied + fences still valid--> effectPrepared
```

`pending` is the wire-level aggregate for `queued`, `claimed`,
`effectPrepared`, and `reconciling`. The phone may show these detailed progress
states, but none is success.

Terminal meanings:

- `applied`: the action-specific semantic effect has authoritative evidence.
- `failed`: authoritative evidence says the effect was not applied and no retry
  remains allowed.
- `indeterminate`: reconciliation cannot prove applied or not applied. This is a
  terminal attention item, never an automatic retry.

Do not encode uncertainty as `failed(.executionFailed)`: that would falsely
claim the effect did not occur. Add an explicit `indeterminate` outcome and bump
the remote protocol minor version. An older client must negotiate observe-only.

## Durable payload envelope

Before opening the acceptance transaction:

1. Load the Keychain-held Guardian remote parent key. Failure rejects the packet
   without consuming nonce or sequence.
2. Generate a random 256-bit data-encryption key (DEK).
3. Encrypt payload with AES-GCM. Bind authenticated data to protocol version,
   command ID, device ID, generation, sequence, revocation epoch, action, target
   thread ID, deadline, and payload digest.
4. Wrap the DEK with the parent key and the same command identity context.
5. Zero transient plaintext/DEK buffers where Swift permits; never stringify.

The journal receives only the sealed payload, wrapped DEK, algorithm/version,
and AAD digest. On claim it unwraps, decrypts, and rechecks SHA-256 against the
signed digest. Any mismatch terminalizes as storage corruption without invoking
an adapter.

After the originating device acknowledges a terminal outcome, erase the wrapped
DEK and sealed payload, retain only digest/outcome/audit metadata, then
checkpoint/truncate WAL. SSD physical deletion remains best effort. Retention
expiry performs the same crypto-shred if the device never ACKs.

## Migrations

Use new append-only migrations; never reinterpret v13-v16 rows in application
code without a migration.

### v17: encrypted execution queue

Create `guardian_remote_command_payloads`:

| Column | Rule |
| --- | --- |
| `command_id` | PK/FK to remote commands |
| `envelope_version`, `algorithm` | supported values only |
| `sealed_payload`, `wrapped_dek` | non-empty blobs |
| `aad_digest` | exactly 32 bytes |
| `created_at` | finite |
| `destroyed_at` | null until crypto-shred |

Create `guardian_remote_command_executions`:

| Column | Rule |
| --- | --- |
| `command_id` | PK/FK |
| `state` | queued/claimed/effect_prepared/reconciling |
| `owner_id`, `lease_generation`, `lease_expires_at` | all null or all present |
| `attempt_count`, `next_attempt_at` | bounded retry state |
| `daemon_generation` | generation that accepted/claimed it |
| `authority_epoch`, `policy_epoch`, `target_revision` | effect fences |
| `adapter_id`, `adapter_version`, `idempotency_key` | fixed before effect |
| `updated_at`, `version` | optimistic CAS |

Existing v15 `pending` commands have no recoverable payload and no executor ever
ran them. Migrate them to `failed(.payloadUnavailable)` with a terminal migration
audit. Never synthesize an empty payload or execute them.

### v18: attempt ledger and truthful outcomes

Create `guardian_remote_command_attempts` keyed by
`(command_id, attempt_number)`. Store lease generation, adapter identity,
idempotency key, fence epochs, state (`prepared`, `invoked`, `reconciled`),
timestamps, bounded diagnostic code, and evidence ID. Never store adapter output
or payload.

Rebuild `guardian_remote_command_outcomes` to allow
`pending/applied/failed/indeterminate`, add `reason_code`, `evidence_id`, and keep
the monotonic `version`. Database checks require terminal time and evidence for
all terminal states. Add `guardian_remote_outcome_acks` keyed by command/device
and outcome version for authenticated crypto-shred.

Migration runs in one transaction, rejects corrupt legacy rows, takes a verified
backup, and prevents binary downgrade after schema advance.

## Journal API

All mutations below are single transactions and use compare-and-swap:

- `acceptRemoteCommand(packet, sealedEnvelope, now)` performs the existing trust
  reconciliation plus payload/queue insertion atomically.
- `claimNextRemoteCommand(owner, generation, now, leaseDuration)` chooses the
  oldest eligible queue item, terminalizes any expired/revoked/stale-generation
  item, and returns one lease.
- `renewRemoteCommandLease(commandID, owner, leaseGeneration, now)` never extends
  past command deadline and rejects a stale owner.
- `prepareRemoteCommandEffect(lease, adapter, fences, evidence)` revalidates all
  durable authority and records the stable idempotency key before external I/O.
- `markRemoteCommandInvoked(lease, attempt)` records the invocation boundary.
- `completeRemoteCommand(lease, terminalOutcome, event)` commits outcome and
  daemon event atomically. Terminal rows reject every later write.
- `releaseOrRequeueRemoteCommand(lease, retryAt)` is allowed only before durable
  effect preparation.
- `claimRemoteCommandForReconciliation(...)` reclaims expired prepared/invoked
  work but cannot authorize a new effect until reconciliation proves not applied.
- `ackRemoteCommandOutcome(device, commandID, outcomeVersion)` verifies ownership
  and atomically records ACK plus payload-key destruction.

Use a resource name such as `remote-command:<commandID>` in the existing lease
table, but claim selection, lease mutation, and execution-row CAS must share one
transaction. Calling the current generic `acquireLease` separately is racy.

## Executor and adapter contract

`GuardianRemoteCommandExecutor` is a daemon-owned actor. It has a bounded poll,
one in-flight task per target thread, a global concurrency cap, shutdown drain,
and no network-facing API.

```swift
protocol GuardianRemoteExecutionAdapter: Sendable {
    var identity: GuardianAdapterIdentity { get }
    func supports(_ action: GuardianRemoteAction) -> Bool
    func reconcile(_ context: GuardianEffectContext) async -> GuardianReconciliationProof
    func apply(_ payload: Data, context: GuardianEffectContext) async -> GuardianApplyResult
}
```

`reconcile` returns exactly one of:

- `applied(evidenceID)`
- `notApplied(evidenceID)`
- `failed(code, evidenceID)`
- `indeterminate(code, evidenceID)`

The executor always reconciles a reclaimed `effectPrepared`/`invoked` attempt
before considering apply. `notApplied` may retry only with the same idempotency
key, unchanged semantic payload, fresh fences, remaining deadline, and a
policy-defined attempt budget. Every retry changes evidence/state; unchanged
blind retries are forbidden.

Codex action proof:

- prompt/steer: exact thread accepted the exact `commandID`/message ID and the
  corresponding turn or message item exists;
- interrupt: exact target turn is terminal/interrupted, or was already terminal,
  with server evidence;
- approve/deny: exact outstanding request ID records the chosen resolution;
- repair/recovery/cancel: the Guardian operation transition committed under the
  authority permit. Later operation progress is delivered as events; command
  `applied` does not falsely mean recovery finished;
- read-only query: response digest and cursor bind the returned result;
- unsupported adapter action: reject before queue acceptance.

If the official Desktop adapter cannot carry a stable message/request ID through
disconnect and restart, prompt/steer stays unavailable remotely. Native
same-task queue remains the fallback; screen/clipboard/TUI evidence is invalid.

## Claim, fence, and crash algorithm

1. Gateway authenticates, validates schema, checks adapter capability, seals the
   payload, and atomically accepts it. Return `pending` receipt only.
2. Executor claims one eligible command with owner UUID and incremented lease
   generation.
3. Decrypt; recheck digest and typed payload. Failure ends before adapter I/O.
4. Read current device, capability, revocation epoch, command deadline, daemon
   generation, authority fence, policy epoch, exact target identity, and required
   fresh impact/safe-point evidence.
5. Atomically write `effectPrepared` and attempt metadata. This is the
   authorization linearization point. A revocation committed before it wins; a
   revocation after it cannot erase an already-authorized attempt and is audited.
6. Recheck deadline immediately before I/O. If the bounded authorization-to-I/O
   window elapsed, return to policy evaluation without invoking.
7. Reconcile. If proved not applied, invoke once with the stored idempotency key.
8. Persist authoritative adapter evidence as applied/failed. On timeout,
   disconnect, or crash boundary, persist/recover as `reconciling`.
9. If reconciliation remains uncertain by deadline/budget, terminalize
   `indeterminate`; alert a person; never invoke again.
10. Publish terminal outcome/event, release lease, and notify clients.

Queued work accepted under an older daemon generation terminalizes as
`failed(.generationChanged)`. Prepared/invoked work from an older generation may
only be reconciled and terminalized; it may not receive a fresh invocation.

## Policy fences

At acceptance and again at effect preparation:

- device is active and exact revocation epoch matches;
- capability maps to the exact action;
- signed deadline is future and maximum TTL is policy bounded;
- daemon generation and authority permit are current;
- policy epoch and adapter capability manifest are unchanged;
- target thread/turn/request identifiers still name the intended object;
- approval/denial references an unresolved exact request;
- destructive recovery has a fresh complete impact snapshot, global safe point,
  restart budget, and closed circuit;
- `force == false` always.

Policy or capability changes after acceptance are allowed to deny execution.
That produces a durable terminal outcome; acceptance is not a promise to bypass
new safety state.

## RED test order

Write each test before its production change.

1. Accepted command currently loses payload after reopen.
2. Keychain/sealing failure consumes no nonce or device sequence.
3. Crash at every acceptance write boundary leaves either all queue records or
   none; never a receipt without encrypted payload.
4. Database/WAL search cannot find known plaintext; decrypt/AAD/digest tampering
   invokes no adapter.
5. Legacy pending migration becomes `payloadUnavailable`, never executable.
6. Two executors racing claim exactly one lease and one attempt.
7. Stale/expired lease cannot renew, authorize, invoke, or terminalize.
8. Crash after claim but before preparation safely requeues after lease expiry.
9. Crash before/after adapter invocation enters reconciliation and produces no
   second semantic effect.
10. `notApplied` retries with the same idempotency key; attempt budget/deadline
    stops it.
11. `indeterminate` is terminal and never rendered as failed or applied.
12. Revocation, deadline, capability loss, policy epoch change, authority epoch
    change, stale generation, stale target, and stale impact snapshot each block
    adapter I/O.
13. Revocation racing effect preparation has one deterministic transaction
    winner and an audit explaining it.
14. Terminal outcome plus daemon event survives crash atomically and cannot be
    overwritten by a stale owner.
15. Offline duplicate returns the original receipt/outcome; conflicting command
    ID never reveals or replaces payload.
16. Only the originating active device can query/ACK; ACK crypto-shreds once and
    duplicate ACK is idempotent.
17. Executor restart recovers queued/claimed/prepared work without loss,
    duplication, infinite pending, or unchanged retry loops.
18. Unsupported/non-idempotent adapter actions are absent from negotiated remote
    capabilities and rejected before durable acceptance.

Fault injection must cover: after encrypted payload insert, after receipt, after
queue insert, after lease claim, after effect preparation, immediately before
adapter call, immediately after adapter call, after evidence write, after
terminal outcome, and after ACK before key destruction.

## Evidence boundaries

Unit/integration tests may prove transaction shape, cryptographic round trips,
lease fencing, state-machine monotonicity, adapter-call counts, migration, and
deterministic fault recovery. They do **not** prove:

- the live Codex Desktop adapter reaches the exact existing Desktop task;
- upstream idempotency survives real disconnect/Desktop restart;
- TLS identity provisioning, pairing UX, network revocation, or private binding;
- Keychain behavior on a signed production build;
- phone background reconnect, notifications, or LAN/VPN p95;
- security clearance, notarization, or public-release privacy.

Phase 8 execution may be merged behind an off-by-default feature fence. Remote
control stays disabled until all are true:

1. No open high/critical security finding from a completed repository scan.
2. Signed production daemon/app pass Keychain and TLS identity live tests.
3. Exact-task adapter idempotency/reconciliation passes real crash/disconnect
   drills for every exposed action.
4. Revocation closes active sessions and prevents claimed-but-not-authorized
   work in a live race test.
5. Deterministic crash matrix shows no lost, duplicated, or forever-pending
   accepted command.
6. Healthy reconnect p95 is below two seconds on the pinned LAN/VPN benchmark.
7. Privacy/secret scan, signing, notarization, and release manifest are green.

Until then: no listener by default, no remote capability advertisement, no
production install, and no claim that Phase 7 or Phase 8 is complete.
