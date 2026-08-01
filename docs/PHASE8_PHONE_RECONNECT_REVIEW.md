# Phase 8 phone reconnect review

Independent bounded review. Findings append below.

## 2026-07-27 source review

Evidence boundary: source inspection only. No build, test, network, background, or device proof.

### Gap map

| Area | Current source evidence | Gap |
|---|---|---|
| Phase 7 server | Signed commands bind device, generation, monotonic sequence, nonce, deadline, revocation epoch, exact thread, action, and payload digest (`GuardianRemoteProtocol.swift:85-128`). Authenticated observe accepts a cursor plus outcome-ACK IDs (`:131-170`). Router returns validated event replay or a full snapshot and idempotent ACK receipts (`GuardianRemoteRequestRouter.swift:69-139`). Outcomes distinguish pending/applied/failed/indeterminate (`GuardianRemoteProtocol.swift:333-388`). | Server seam is usable. Phone does not consume it. |
| Production service | Every `ProductionGuardianPhoneService` operation throws `transportUnavailable` (`GuardianPhoneService.swift:24-37`). | No pairing wiring, TLS client, authenticated observe, mutation, reconnect, or outcome reconciliation. |
| Operational codec/auth | Phone has a signed pairing-only codec. Operational Phase 7 wire DTOs/signing are absent from `GuardianPhoneCore`; `GuardianPhoneCore` has no dependency on the server contract (`Package.swift:26-32`). | Cannot create signed observe/mutation packets or strictly validate observation/event/outcome responses. Private pairing-only schema clones invite protocol drift. |
| TLS/reconnect | Certificate hash validation exists as a pure helper, but no `NWConnection` phone client calls it. Store performs one `loadSnapshot()` call. | No pinned TLS exchange, timeout/cancellation, retry/backoff, foreground/background reconnect, or connection-generation fencing. |
| Cursor | `ProjectionCursor` only checks one in-memory envelope (`GuardianPhoneSafety.swift:232-265`). | No durable server cursor, atomic snapshot/event application, replay loop, snapshot-required recovery, or cursor advance after successful projection commit. |
| ACK/outcomes | Server supports outcome ACK batches and returns ACK receipts. | Phone has no durable `ackPending` set, resend-until-receipt loop, lost-ACK recovery, or outcome-version validation. |
| Command history | UI model carries at most one optional command per task. | No durable commandID-to-exact-thread map; no accepted-vs-applied history; no indeterminate/manual-review state reconciliation after reconnect. |
| Offline queue | `OfflineCommandQueue` is an in-memory array of presentation records and only deduplicates `OperationID` (`GuardianPhoneSafety.swift:286-308`). | It lacks payload, exact target/generation, signed bytes, stable UUID/nonce/sequence, deadline, revocation epoch, persistence, drain policy, and ambiguous-send reconciliation. It must not blindly regenerate or resend a different command. |
| Keychain state | Keychain stores only device identity and paired Guardian (`GuardianPhonePairingStorage.swift:76-124`). | Cursor, next sequence, exact pending packet, outcome/ACK state, and projection checkpoint are not durable. Corrupt/missing state policy is unspecified. |

### Recommended seams

1. Add `Sources/GuardianRemoteContract/`: cross-platform protocol DTOs, canonical encoder, framing, action/capability mapping. Move shared Phase 7 contract out of `GuardianCore`; depend on it from both `GuardianCore` and `GuardianPhoneCore`. Avoid a second private operational schema.
2. Add `Sources/GuardianPhoneCore/GuardianPhoneRemoteCodec.swift`: construct/sign immutable packets from paired identity; verify request ID, device ID, command ID, payload digest, generation, sequence, outcome version, and response kind.
3. Add `Sources/GuardianPhoneCore/GuardianPhoneSessionState.swift`: actor owning one atomic durable record: pairing epoch, revocation epoch, cursor, next command sequence, pending immutable packets, received outcomes, pending ACK IDs, and last projection checkpoint. Back it with versioned Keychain storage; fail closed on corrupt or cross-device state.
4. Add `Sources/GuardianPhoneCore/GuardianPhoneOutbox.swift`: persist-before-send state machine: `queued -> ambiguous/accepted -> applied|failed|indeterminate -> ackPending -> acknowledged`. Reconnect first reconciles the exact stored packet/command ID; never creates a replacement command for an ambiguous send.
5. Add `Phone/CodexGuardianPhone/GuardianPinnedTLSClient.swift`: `Network.framework` TLS 1.3 client, exact leaf-DER SHA-256 pin, bounded frame, one completion, cancellation, deadline, and connection-generation token.
6. Replace the production stub with an actor-backed `ProductionGuardianPhoneService`: pairing coordinator + pinned exchange; signed observe loop; replay/snapshot reducer; bounded exponential backoff with jitter; capability/revocation downgrade; serialized outbox drain.
7. Add `Phone/CodexGuardianPhone/GuardianPhoneProjectionMapper.swift`: atomically map full snapshots/events/outcomes to tasks and command history. Publish UI state only after cursor/checkpoint persistence succeeds.

### RED-first order

1. Crash after server acceptance/before phone response: reconnect uses the identical stored packet; one server command, one UI record.
2. Response received/ACK response lost: pending ACK survives relaunch and repeats until matching ACK receipt; no payload/key loss before receipt.
3. Event gap or generation change: no partial projection; require full snapshot; block mutations until new snapshot and checkpoint commit.
4. Wrong device/thread/command/outcome-version response: reject without cursor, history, or queue mutation.
5. Offline relaunch: cursor, next sequence, immutable packet, and command history survive; expired command becomes visible failed/review, never silently replaced.
6. Revocation or pairing-epoch change: stop drain, discard authorization, preserve non-secret audit metadata, require re-pair.
7. Corrupt Keychain/session record: fail closed and surface recovery; never silently rotate identity or reset sequence.
8. Background cancellation during header/body receive: exactly one terminal callback; next foreground reconnect starts one session and preserves state.

Conclusion: server reconnect/ACK primitives are materially ahead of the phone. Phase 8 remains unproven until the operational codec, durable session/outbox, pinned transport, projection reducer, and production-service integration exist and pass the fault cases above.
