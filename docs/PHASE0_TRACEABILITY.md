# Phase 0 Evidence and Traceability

Date: 2026-07-27

## Pinned baseline

| Component | Version / revision | Evidence |
| --- | --- | --- |
| Guardian source | `dd3c209` | `git rev-parse --short HEAD` |
| Guardian baseline tests | 51 passing | `swift test -q` |
| Codex Desktop | `26.721.41059`, bundle `com.openai.codex` | Installed `Info.plist` |
| Bundled Codex CLI | `0.146.0-alpha.3.1` | Bundled binary `--version` |
| Global Codex CLI | `0.142.0` | Resolved binary `--version` |
| OpenAI Codex reference | `95637f7056835fea66bdd0044414af480fc0fd74` | Upstream `HEAD` |
| Paseo comparison | `1a1ff8828f002fce08e239bae3d46aff75e22f52` | Upstream `HEAD` |

Pins describe the comparison snapshot. Release work must replace moving `HEAD` pins with immutable tags where available.

## Existing observed-symptom proof

| Invariant | Regression evidence | State |
| --- | --- | --- |
| Requester's verified heartbeat cannot block itself | `requestedStuckTaskDoesNotBlockItsOwnRecovery` | Proven unit |
| Real resumed requester work blocks restart | `resumedWorkInRequestedTaskBlocksRestart` | Proven unit |
| Unrelated active work blocks restart | `activeParallelTaskBlocksRestart` | Proven unit |
| Missing/truncated task evidence fails closed | `missingOriginActivityFailsClosed`, `scannerReportsWhenItsSafetyViewIsTruncated` | Proven unit |
| Desktop launch alone is not readiness | `desktopLaunchAloneCannotReleaseContinuation` | Proven unit |
| Relaunch requires a new process and settle window | `hardRecoveryRequiresANewCodexProcess`, `continuationWaitsForVerifiedDesktopRelaunch`, `appServerGetsAFullSettleWindowAfterItAppears` | Proven unit |
| Exact origin thread is resolved | `originTokenSelectsExactCallingThread` | Proven unit |
| Detached CLI continuation is forbidden | `recoveryMustNotLaunchDetachedCodexCLI`, `continuationLauncherRefusesDetachedResumeCommand` | Proven unit |
| Hard recovery needs no human Send | `hardRecoveryDoesNotRequireAHumanToPressSend` | Proven unit |
| Duplicate origin is idempotent; conflict fails | `repeatedOriginTokenIsIdempotentAndConflictFailsClosed` | Proven unit |
| Concurrent requests do not overwrite | `concurrentChatRequestsDoNotOverwriteEachOther` | Proven unit |
| Continuation has one expiring owner | `continuationDeliveryUsesAnExpiringSingleOwnerLease`, `concurrentContinuationLeaseHasExactlyOneOwner` | Proven unit |
| Abandoned lock wait is bounded | `abandonedStateLockFailsWithABoundedBusyError` | Proven unit |
| Corrupt item isolates; I/O uncertainty fails closed | `corruptPendingRequestIsPreservedWithoutBlockingValidRecovery`, `queueIOFailureFailsClosedInsteadOfQuarantiningUnknownData` | Proven unit |
| Paused/wrong-thread heartbeat fails closed | `pausedOrWrongThreadHeartbeatFailsClosed` | Proven unit |
| Automation ID cannot escape state directory | `automationIdentifierCannotEscapeItsStateDirectory` | Proven unit |
| Model output cannot issue recovery control | `inventedToolCallFallsBackToKnownSafePrompt`, `recoveryControlCommandFallsBackInsteadOfRestartingAgain` | Proven unit |
| Large subprocess output cannot deadlock capture | `processOutputCaptureDrainsMoreThanAPipeBuffer` | Proven unit |

## Gate 0 live evidence

| Question | Current evidence | Decision |
| --- | --- | --- |
| Is a Desktop-owned local socket present? | Socket mode `0600`; held by the Desktop process | Necessary, not sufficient |
| Does bundled Codex expose a control proxy? | `app-server proxy --sock` exists | Necessary, not sufficient |
| What framing does the socket use? | Official protocol: WebSocket HTTP Upgrade plus WebSocket frames over Unix socket | Raw JSONL is invalid |
| Does the generated schema expose observation? | `thread/list`, `thread/loaded/list`, `thread/read`, status notifications | Candidate read path |
| Does it expose correlated input? | `turn/start.clientUserMessageId`; user item echoes `clientId` | Candidate exact-delivery path |
| Has Guardian completed a live handshake? | No. WebSocket Upgrade to `ipc.sock` received immediate EOF. Desktop child app-server runs default stdio and exposes no Unix control listener. | Gate blocked by missing supported listener |
| Can Guardian attest the exact Desktop child and transport without mutation? | Yes. `guardianctl codex-control` revalidated Desktop PID/start epoch around a wide `ps` snapshot, selected exact bundled child PID `22468` with parent Desktop PID `22091`, and reported `stdio`. | Discovery proven only; no semantic attach or write authority |
| Has Guardian proved same Desktop process/session and UI synchronization? | No | Gate open |
| Has message ID survived ambiguous disconnect and Desktop restart? | No | Gate open |
| Is Desktop discovery/relaunch bound to signed bundle URL and PID/start epoch? | Yes. `guardianctl codex-process` resolved the live Developer ID-signed OpenAI bundle and captured PID/start identity. | Process subgate proven; no restart drill performed |

## Missing fail-first proof, ordered

1. WebSocket-over-Unix handshake, masking, and frame parsing.
2. Read-only initialize plus `thread/loaded/list` against the Desktop-owned socket.
3. Exact Desktop process/session binding and UI synchronization.
4. Workload inventory reports `complete`, `partial`, or `unavailable`.
5. Exact message/thread receipt using one disposable task.
6. Ambiguous send plus Desktop restart reconciles by client message ID.
7. Destructive live drill of the source-proven PID/start-identity/process-epoch fence.
8. Serialized final restart barrier catches a turn starting at the boundary.
9. Shadow daemon and journal replay before authority cutover.

## Phase 0 exit

- Baseline pinned: complete.
- Existing symptom traceability: complete.
- Public benchmark fixture: `Benchmarks/GuardianBench/fixtures/v1/scenarios.json`.
- Gate 0 transport proof: exact child/transport discovery proven; supported same-Desktop listener absent, so Gate 0 remains open.
- Upstream boundary: existing [openai/codex#25914](https://github.com/openai/codex/issues/25914) matches the gap. Guardian has not published an upstream comment.

## Red/green evidence

### WebSocket control codec

- Theory: raw JSONL stalled because the documented Unix control transport requires HTTP Upgrade and RFC 6455 frames.
- Red: `swift test --filter CodexControlWebSocket -q` failed because `CodexControlWebSocket` did not exist.
- Fix: added upgrade validation, masked client text frames, and incremental unmasked server-frame decoding.
- Green: 4 focused tests passed; full suite passed 55/55.
- Live boundary: Desktop's current app-server is stdio-owned by Desktop. Its private `ipc.sock` is not the supported app-server control listener. Direct external same-task attachment remains unproven and disabled.

### Desktop control capability gate

- Theory: socket existence/ownership can be mistaken for an attachable semantic control plane.
- Red: 4 focused tests failed because no executable capability policy existed.
- Fix: added a fail-closed policy covering Desktop-child identity, supported listener, socket owner, schema support, inventory completeness, UI synchronization, and durable message correlation.
- Green: 4 focused tests passed; full suite passed 59/59.
- Current installed mode: `.unavailable(.noSupportedControlListener)`; no write/control claim is permitted.
- Red: the exact-child parser APIs were absent; then a config value named `app-server` incorrectly impersonated the real subcommand.
- Green: 12 focused process/transport tests pass. Detached, ambiguous, malformed, management, conflicting-listener, and lookalike-path evidence fails closed.
- Live: `guardianctl codex-control` returned `unavailable:noSupportedControlListener`, `inventory: unavailable`, and both UI/persistence proofs false. It performed no socket connection, daemon launch, prompt, or restart.

### Signed Desktop process controller

- Theory: bundle-ID plus PID-set discovery can target a different stable/beta installation, accept signing drift, or mistake PID reuse for the intended process epoch.
- Red: focused tests failed because no process trust, selection, controller, or macOS discovery API existed.
- Fix: added exact bundle/signing/team selection; LaunchServices enumeration; strict Security validation; PID/start-identity fencing; exact-path launch revalidation; already-stopped relaunch support; and `AppModel` integration.
- Green: 18 process-focused tests passed; current full suite passed 357 tests in 12 suites.
- Live read-only proof: `/Applications/ChatGPT.app`, bundle/signing `com.openai.codex`, team `2DC432GLL2`, PID `22091`, start identity `1785099181648714`.
- Signing proof: hardened Developer ID, stapled notarization, and Gatekeeper acceptance.
- Phone compile proof: generic iOS Simulator `build-for-testing` succeeded. No simulator runtime/device proof.
- Boundary: no destructive restart drill was performed. Gate 0 remains open because exact Desktop semantic read/write is still unavailable.
