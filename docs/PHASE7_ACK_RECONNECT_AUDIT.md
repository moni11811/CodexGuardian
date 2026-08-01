# Phase 7 ACK and Reconnect Audit

## Failure theory

Terminal outcome acknowledgement existed only as a journal method. A phone could
receive a terminal result, reconnect, and replay events, but could not submit an
authenticated ACK over the remote protocol. The operation payload therefore
remained decryptable indefinitely. Read-only observe requests were also inserted
into the execution queue even though executors skip them, leaving permanent
pending outcomes.

## Implemented contract

- A signed observe payload can carry at most 100 unique command IDs to ACK.
- Only the originating active device may ACK its immutable terminal outcome.
- Observation and replay responses return explicit durable ACK receipts.
- Duplicate reconnect returns the original ACK receipt and one audit event.
- ACK destroys the encrypted payload row and best-effort truncates SQLite WAL.
- Read-only observe bypasses payload-key creation, stores no payload or execution
  lease, and atomically records an applied outcome.
- Protocol 1.0 observe payloads without the new ACK field decode as an empty ACK
  list; duplicate IDs fail request validation.

## Regression evidence

- `authenticatedReconnectAcknowledgesTerminalOutcomeAndShredsPayload`
- `readOnlyObserveNeedsNoPayloadKeyAndCannotRemainQueued`
- `protocolOneObserveWithoutAckFieldRemainsCompatible`
- `reconnectAcknowledgementBatchIsAtomic`

The first two are green. Compatibility and batch atomicity were added red-first;
their final green rerun is required after concurrent target work settles.

## Remaining release boundaries

- Live TLS identity provisioning and real LAN/VPN reconnect drill: unproven.
- Healthy LAN/VPN p95 under two seconds: unmeasured.
- Completed repository security scan with no open high/critical findings: absent.
- Native iPhone client/background reconnect: Phase 8.

Remote remains disabled by default and production bootstrap remains observe-only.
