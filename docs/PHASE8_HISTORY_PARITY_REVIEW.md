# Phase 8 history parity review

Status: source parity implemented; live Mac/iPhone drill not yet proven.

## Bug theories

1. The Mac full snapshot exposed only coarse current recovery operations. The
   phone discarded them, so the two operators could not show the same history.
2. Remote mutation outcomes lived only in the phone process. Reconnect erased
   action, exact target, and authoritative pending/applied/failed state.
3. An unbounded history page could exceed the 512 KiB remote frame and turn a
   long-running Guardian into a permanent reconnect failure.
4. Snapshot-only command history would be skipped whenever cursor replay
   returned an event batch.

## Implemented contract

- Recovery history: canonical journal operations in the Mac snapshot. Latest
  100 items, exact total, and `complete`/`truncated`; absent legacy field means
  `unavailable`.
- Command history: migration v21 stores immutable metadata for non-observe
  commands only. The query is scoped to the authenticated device and joins the
  signed command, receipt, and outcome.
- Each command item carries action, exact thread, expected generation, issue
  time, deadline, receipt, outcome version, and update time. Mirrored-field
  disagreement is corruption and fails closed.
- Snapshot and event-batch observe responses carry the same optional page.
- Phone decoding requires exact device, digest, generation, sequence, dates,
  outcome version, unique IDs, canonical newest-first ordering, and valid page
  completeness.
- Durable phone merge is monotonic. An older pending/accepted page cannot
  downgrade a newer terminal outcome. Missing legacy history preserves local
  history and remains explicitly unavailable.
- Mac and phone Recent views expose separate recovery and command histories.
  Accepted never renders as applied; indeterminate renders as needs review.

## Red then green evidence

- Missing journal API/page types failed compilation.
- Device-scoped storage test observed three rows because observe heartbeats were
  indexed; mutation-only projection reduced it to two.
- Router test failed because snapshot/event batch had no command history.
- Phone codec tests failed because reconnect history/unavailable state did not
  exist.
- Session tests failed because no metadata-checked monotonic merge existed.
- Client test failed because the returned snapshot dropped command history.
- iPhone projection test failed because app models dropped the page.
- Signed-metadata regression observed invalid generation and expired deadline
  accepted as valid before the invariant fix.

Current verification: 328 Swift tests in 12 suites pass. Generic iOS Simulator
`build-for-testing` passes. No installed Simulator or physical-device run exists,
so runtime UI, LAN reconnect, and end-to-end remote recovery remain unproven.

## Remaining Phase 8 gap

Production Mac semantic mutation adapters and authoritative impact/diff/
checkpoint providers are still absent. Phone mutation controls correctly remain
disabled. History parity does not authorize them.
