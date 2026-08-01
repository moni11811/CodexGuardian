# Phase 8 command semantics review

Owner: accepted-versus-applied regression lane.

## Bug theory

The journal proves only that a signed command was durably accepted. The current
router returns that acceptance through the generic gateway response, so a phone
cannot distinguish queued work from a side effect that actually ran. A lost
connection makes this worse: retrying the same offline command returns the same
receipt but still supplies no execution state, inviting a false success UI or a
duplicate side effect outside the journal.

## Required contract

- A durable receipt is returned as an explicit command outcome in `pending` state.
- `applied` and `failed` are terminal states distinct from `pending`.
- Every state carries the exact original acceptance receipt.
- An identical offline retry returns the exact same receipt and `pending` state.
- Wire encoding preserves all three states; acceptance alone never means applied.

## RED evidence

Focused compile exited 1 because command outcome types, wire case, and durable
receipt lookup did not exist. No unrelated product failure.

## GREEN evidence

Every accepted non-observe command now receives a durable pending outcome.
Identical offline retry returns the original receipt and same pending state.
Pending, applied, and failed wire round-trips passed 2/2 focused tests.
