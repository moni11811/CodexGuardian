# Phase 8 Remote Command History Review

## Bug theory

Remote mutation acknowledgements currently live only in the phone process. A reconnect can therefore erase which authenticated device issued a command, its exact task target, and its authoritative outcome. The phone can then show an unprovable applied state.

## Review findings

Current state is not reconnect-authoritative:

- `guardian_remote_commands` durably stores the signed command and receipt. Action,
  exact target, and issue time exist only inside `command_json`.
- `guardian_remote_command_outcomes` durably distinguishes pending, applied,
  failed, and indeterminate. `remoteCommandOutcome(commandID:)` exposes one item,
  but no device-scoped history query exists.
- The router returns the current mutation outcome only on that mutation request.
  Observe responses carry ACKs plus snapshot/events, not prior outcomes.
- The phone outcome omits action, target, issue time, deadline, and outcome version.
  Its history is therefore local-process state, not a verifiable Mac projection.

## Required durable schema

Add migration `guardian-journal-v21-remote-command-history-metadata` with an
immutable projection table:

`guardian_remote_command_history_metadata(command_id PRIMARY KEY REFERENCES
guardian_remote_commands ON DELETE CASCADE, device_id REFERENCES
guardian_remote_devices, action, target_thread_id, expected_generation,
issued_at, deadline)`.

The table contains non-observe commands only. Add an index on
`(device_id, issued_at DESC, command_id DESC)`. Backfill it transactionally by
decoding and validating every existing `command_json`; abort migration on a
malformed command. Insert new metadata in the same transaction as command,
receipt, pending outcome, execution row, device sequence, and audit.

On read, join metadata, commands, receipts, and outcomes. Re-decode
`command_json` and require every duplicated field, receipt device/generation/
sequence/digest, and outcome version to agree. Any disagreement is journal
corruption, never a partial history result.

Expose `remoteCommandHistory(deviceID:limit:)`. It must:

- require `1...100`;
- filter by the authenticated device before count and pagination;
- exclude `.observe` in storage and query;
- fetch `limit + 1` in canonical `(issuedAt, commandID)` descending order;
- return at most 100 items, device-local `totalCount`, and explicit
  `complete` or `truncated` completeness;
- use one SQLite read transaction so count and page describe one state.

No payload, prompt text, nonce, signature, key material, or another device's
count may enter the page.

## Wire contract

Add `GuardianRemoteCommandHistoryItem` containing:

- receipt: command ID, device ID, payload digest, accepted generation,
  sequence, and accepted time;
- action, exact target thread ID, expected generation, issued time, deadline;
- authoritative outcome state, outcome version, and update time.

Add `GuardianRemoteCommandHistoryPage(items,totalCount,completeness)` with a
hard 100-item maximum. Add optional `commandHistory` to both
`GuardianRemoteObservation` and `GuardianRemoteEventBatch`. Optional is needed
for protocol-1.0 decoding: absent means `unavailable`, not empty or complete.
Returning the page on both paths prevents event-replay reconnects from missing
terminal transitions indefinitely.

The router derives the history device only from the authenticated signed
observe command. It must never accept a device selector in observe payload.
Query after ACK processing, then attach that same page to snapshot or event
response. Any history read/corruption failure returns `serverUnavailable`; it
must not silently omit an authoritative field for a history-capable server.

## Phone validation and merge

Mirror the page as an optional exact wire type. Decode only when all of these
hold:

- item count is at most 100; IDs and `(deviceID,sequence)` pairs are unique;
- every device ID equals the paired/expected device;
- digest is 32 bytes; generations, sequence, and outcome version are positive;
- target is non-empty and bounded; action is known and is not observe;
- dates are finite and ordered `issuedAt < deadline`, `issuedAt <= acceptedAt`,
  and terminal/update times are not before acceptance;
- list order is canonical and `totalCount >= items.count`;
- completeness is `complete` iff `totalCount == items.count`, otherwise
  `truncated`.

For a matching durable local request, also require command ID, device ID,
payload digest, sequence, expected generation, action, exact target, issue time,
and deadline to match. A mismatch rejects the whole response. Merge by command
ID and monotonic outcome version; never let an older page downgrade a newer
terminal state.

Presentation must stay honest:

- locally queued, no receipt: `pending` / “Waiting for Guardian”;
- authoritative pending outcome with receipt: `accepted` / “Accepted by Guardian”;
- only authoritative applied: `applied`;
- authoritative failed: `failed` with code;
- authoritative indeterminate: `needs review`, never applied.

A legacy `nil` page becomes `unavailable` and preserves durable local history.
A truncated page cannot prove omitted commands disappeared. Even a complete
page must not invent failure for an unmatched local request; retain it as
pending/needs-review until explicit reconciliation. Mutation controls remain
disabled until the corresponding adapter and authorization evidence are live.

## RED tests required before implementation

Add these exact tests first:

1. `GuardianRemoteCommandHistoryTests.remoteCommandHistoryIsDeviceScopedAndExcludesObserve`
2. `GuardianRemoteCommandHistoryTests.remoteCommandHistoryPageIsBoundedAndReportsTruncation`
3. `GuardianRemoteCommandHistoryTests.corruptMirroredMetadataFailsClosed`
4. `GuardianRemoteRequestRouterTests.observeResponsesCarryDeviceCommandHistoryOnSnapshotAndEventBatch`
5. `GuardianPhoneRemoteCodecTests.legacyObservationWithoutCommandHistoryDecodesAsUnavailable`
6. `GuardianPhoneRemoteCodecTests.commandHistoryRejectsCrossDeviceAndMetadataMismatch`
7. `GuardianPhoneSessionStateTests.reconnectMergesAuthoritativeHistoryWithoutUpgradingPendingToApplied`
8. `GuardianPhoneSessionStateTests.olderHistoryCannotDowngradeTerminalOutcome`

## Evidence

Implemented after red regressions. Current full Swift package run passes 328
tests in 12 suites. Generic iOS Simulator `build-for-testing` passes. Runtime
Simulator/device and live network recovery proof remain separate and absent.
