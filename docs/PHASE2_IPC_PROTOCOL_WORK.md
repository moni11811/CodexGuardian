# Phase 2 IPC protocol work log

Append-only implementation notes and fail-first evidence for local Guardian client/daemon envelopes.

## 2026-07-26

- Theory: unversioned, role-blind commands permit stale-generation, cross-thread, force-authority, and reconnect ambiguity.
- Red: `GuardianIPCProtocolTests` failed to compile because all protocol contracts were absent.
- Green: eight focused IPC tests passed after adding versioned commands/snapshots/events, role/capability validation, origin binding, deadlines, sequence-gap resnapshot, and deterministic disconnect expiry.
- Boundary: these are pure contracts. Socket peer authentication and daemon transport remain Phase 2 work.
