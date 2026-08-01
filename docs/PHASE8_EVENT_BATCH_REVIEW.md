# Phase 8 event-batch reconciliation review

## Bug theory

After reconnect, the Mac can return a valid `eventBatch`. The phone previously
decoded only full observations, so the batch failed as `invalidResponse`. A
naive retry would resend the same stale cursor forever because event records do
not contain enough task data to rebuild the phone dashboard.

## Contract

- Bind receipt, device, payload digest, generation, and prior cursor.
- Reject gaps, generation changes, invalid operation IDs, invalid dates, and
  batches larger than the requested 100-event bound.
- Persist the first observe outcome and ACK debt before further network I/O.
- Clear the stale cursor and make exactly one cursorless full-snapshot request.
- Persist that second request before send so a disconnect resends identical
  bytes and never duplicates a logical command.
- Reject a second batch instead of looping.

## Evidence

Two regressions were written and observed failing with `invalidResponse` before
the implementation changed:

- Mac event-batch wire compatibility.
- One-call event-batch to authoritative-snapshot reconciliation.

After the fix, both pass. The broader phone protocol suite passes 27 tests in
8 suites. The Mac remote protocol suite passes 14 tests. Generic iOS Simulator
`build-for-testing` succeeds. No simulator is installed, so launch/UI/network
runtime proof remains open.
