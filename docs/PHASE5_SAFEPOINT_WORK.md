# Phase 5 safe-point work log

Append-only implementation notes and test evidence for global restart safety policy.

## Pure safe-point decision core

Theory: a restart is unsafe whenever Guardian has absence of evidence rather than positive proof of a global safe point. The automatic path therefore fails closed unless one fresh, complete, schema-supported, sequence-contiguous, conflict-free inventory at the expected generation shows every real task idle.

Design:

- `SafePointPolicy` is deterministic and side-effect free. Callers provide the request, inventory, and clock.
- Any unrelated active task blocks. Resumed ordinary work in the requesting task also blocks.
- An active task is ignored only when its verified heartbeat proof exactly matches operation ID, origin thread ID, and origin token.
- Stale snapshots, sequence gaps, incomplete inventory, unsupported schema, and conflicting evidence are explicit `unknown` blockers.
- A generation mismatch returns `resnapshotRequired`; the caller may not reuse the earlier decision.
- Force is not an automatic override. A requested force returns `humanForceRequired` for a separate human-controlled path.
- Blocking thread IDs are de-duplicated and sorted so identical input produces stable output.

Fail-first evidence:

- `swift test --filter SafePointPolicyTests` failed to compile because `SafePointRequest`, `SafePointInventory`, `SafePointPolicy`, and related types did not exist.
- This established the required policy surface before implementation.

Green evidence:

- `swift test --filter SafePoint`
- Result: 12 tests passed, 0 failed.
- Covered unrelated activity, requester resumed work, exact verified heartbeat exemption, unverified/wrong-operation heartbeat rejection, five unknown states, generation fencing, all-idle permission, and non-automatic force behavior.
