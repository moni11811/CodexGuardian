# Phase 8 phone remote implementation log

## Implemented

- Keychain device identity and pairing record with private-endpoint validation.
- QR invitation/claim/receipt interoperability with the Mac protocol.
- TLS 1.3 Network.framework exchange with exact leaf-certificate SHA-256 pin.
- Signed observe packets and exact Mac wire compatibility.
- Durable cursor, monotonic command sequence, immutable pending frames, terminal
  outcome history, and ACK debt.
- Ambiguous disconnect resends the exact stored bytes.
- Event batches validate continuity, then trigger one bounded cursorless full
  snapshot request instead of repeating a stale cursor.
- Concurrent refreshes share one exchange. Foreground cancellation cancels the
  shared transport.
- Active-scene reconnect supervisor with capped exponential backoff. Only
  transient network failures retry; deterministic failures open the circuit.
- Bounded per-device remote command history on both snapshot and event-replay
  paths, with exact action/target metadata and monotonic durable phone merge.
- Recovery and command history reach the native Recent UI with explicit
  unavailable/truncated states. Accepted is never presented as applied.

## Red-first evidence

- Pairing record reload returned nil because sync actor overloads bypassed the
  async protocol requirement.
- Public stored endpoint was accepted.
- First observe with unknown generation was rejected.
- Event-batch responses failed as `invalidResponse`.
- Two concurrent observes sent two network exchanges.
- Cancelling the foreground observe did not cancel its transport.
- Reconnect policy types and lifecycle integration did not exist.
- Command history API, router fields, phone codec/session merge, client snapshot,
  and app projection did not exist.
- Observe heartbeats incorrectly occupied the history index.
- Invalid history generation and expired-at-acceptance deadline passed the core
  item validator.

Each symptom was observed failing before its source fix.

## Current proof

- Full Swift package run passes 328 tests in 12 suites.
- Generic iOS Simulator `build-for-testing` is green, including app tests.
- No Simulator runtime exists on this Mac. App lifecycle tests compile but have
  not executed.
- No physical-device LAN/TLS, suspension, BG refresh, APNs, VPN, or latency
  claim exists.
- Production mutation adapters remain unavailable, so prompt/restart controls
  stay disabled.
