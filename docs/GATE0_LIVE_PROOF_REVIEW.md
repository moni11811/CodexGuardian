# Gate 0 Live Proof

## Authorized outcome

Create one disposable Codex Desktop task, deliver one unique harmless marker
through an independent installed `codex app-server` process, and prove the same
Desktop task records the exact reply. No restart.

## Status

PASSED. Independent app-server resumed the exact Desktop task and completed the
marker turn. The Desktop task read contained the same marker and exact ACK.

## Direct evidence

- Task: `019fb9a8-72f4-78c0-a995-baf2c5835d32`
- Origin marker: `F3D71921-D797-4B8B-BE50-312FBB5C81C8`
- Completed turn: `019fb9ae-d0ec-7dd3-a8d1-2a827b364803`
- Desktop reply: `GUARDIAN_GATE0_ACK F3D71921-D797-4B8B-BE50-312FBB5C81C8`
- Turn duration: 162.391 seconds
- Trace: `/tmp/CodexGuardianGate0Trace-F3D71921-D797-4B8B-BE50-312FBB5C81C8.jsonl`
- Cleanup: disposable task archived; Codex was not restarted.

## Finding

A fresh app-server emitted continuous MCP startup and hook progress before the
model reply. A fixed 60-second timeout would falsely call this stuck. Guardian
must treat correlated startup/hook events as liveness, while separately bounding
true no-progress time.

The first probe was manually stopped at 57.909 seconds and therefore produced an
empty interrupted turn. The changed probe retained the same origin marker, added
sanitized event tracing, waited within its 180-second bound, and passed.

## Regression

`script/test_gate0_live_proof_driver.sh` failed before the driver existed, failed
again when the driver lacked a legal Swift `@main`, then passed after both fixes.

## Worker preflight

- Block live proof: coordinator stops at `turn/completed`; it never re-reads the thread to prove the unique marker and exact assistant reply persisted in the resumed task.
- `turn/start` parsing accepts any nonempty turn ID; it does not bind that response turn to the requested thread. Require final `thread/read` matching thread ID, client marker, returned turn ID, and exact reply before claiming proof.
- Safe disposal: use a freshly created task only; never use a live task, and retain its ID/marker only in the proof artifact.

Final Desktop re-read satisfied the worker's task ID, marker, returned turn ID,
and exact-reply binding requirement.
