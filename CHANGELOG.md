# Changelog

This project has not published a stable binary release yet. Changes below describe the current source snapshot and locally installed development build, not a notarized public download.

## Unreleased

### Added

- macOS shield menu app and recovery dashboard
- always-on launchd daemon with authenticated local IPC
- durable SQLite WAL journal, outbox, leases, receipts, and operation history
- MCP tools for status, native recovery, hard-recovery preparation, heartbeat delivery, and acknowledgement
- exact-task direct native recovery through Codex’s desktop queue
- Guardian-owned idempotent native app-server recovery and reconciliation
- progress-aware task states, readiness, multi-task safe-point, authority, restart-budget, and circuit policies
- trusted Codex application/process discovery
- local Apple Foundation Models continuation adviser with deterministic fallback
- transactional release build/install/rollback and archive-preserving uninstall
- deterministic GuardianBench runner
- experimental iOS pairing, observation, reconnect, and dashboard foundations

### Fixed

- same-task recovery continuation no longer depends on copy/paste or Accessibility Send
- restart heartbeat no longer counts as unrelated work while real resumed work still blocks
- concurrent recovery callers cannot overwrite or duplicate one operation
- ambiguous native delivery is reconciled before resend
- corrupt queue records are isolated while I/O uncertainty fails closed
- production daemon owns its protected Unix socket instead of relying on failed launchd socket handoff
- production activation failures identify the exact failed stage and rollback safely
- production build uses release configuration and does not stop the working app before a build-only step
- launchd jobs start with a clean environment so unrelated tokens are not inherited

### Known limitations

- unattended hard restart is disabled until authoritative complete Codex Desktop control is available and live-proven
- phone mutation commands and public remote deployment are unavailable
- public binary signing, notarization, updater, and stable versioning are not complete
- compatibility with future private Codex app-server behavior is not guaranteed
