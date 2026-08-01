# Phase 3 classifier work log

Append-only implementation notes and test evidence for the authoritative task-state classifier.

## 2026-07-26 — pure classifier slice

Theory: absence of output is not authoritative evidence of a stuck task. Classification must fail closed unless one complete snapshot and a contiguous, same-generation event stream provide fresh, high-confidence evidence.

Fail-first evidence:

- `TaskStateClassifierTests.swift` was added before production code.
- First focused run exited 1 before reaching the new tests because concurrent `GuardianJournal.swift` did not compile (`fetchOperation(originTokenHash:from:)` missing). This proved only the upstream build blocker, not classifier behavior; no false red claim.

Green evidence:

- After the journal blocker cleared, `swift test --filter TaskStateClassifierTests` passed: 9 test functions, including 5 parameterized cases, 0 failures.
- Build completed with the new classifier and all linked package products.

Design:

- Pure deterministic policy. No UI, filesystem, process, or network access.
- Evidence carries task/source identity, observation and expiry time, server generation, event sequence, confidence, inventory completeness, and verified-heartbeat status.
- Missing/incomplete snapshots, stale or weak evidence, generation conflicts, sequence gaps, and semantic conflicts return `unknown`; recovery callers receive `requiresFullSnapshot` where resynchronization can resolve uncertainty.
- Approval, authentication, and permission waits classify `waitingUser`.
- Fresh progress, owned work, or requester work classifies `running`; quiet never implies stuck.
- Only explicit coherent `stalled` evidence classifies `stuck`.
- A verified Guardian recovery heartbeat is ignored as synthetic activity. Real resumed requester work still classifies `running` and blocks restart.
