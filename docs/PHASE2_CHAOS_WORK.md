# Phase 2 crash/reopen work log

Append-only evidence for real child-process journal durability checks.

## 2026-07-27

- Theory: in-process reopen tests cannot expose state lost when the writer process dies immediately after a SQLite commit. An outbox attempt lost at this boundary could resend a continuation twice.
- Red: `./script/test_journal_crash_replay.sh` exited 1 with `error: no product named 'guardian-journal-crash-worker'`. The harness existed before its worker implementation.
- First integration attempt then failed at compile because throwing reads were inside a non-throwing assertion autoclosure. The reads were hoisted without changing journal behavior.
- Green: real worker processes committed, published a marker, stopped, and were killed with `SIGKILL`. Reopen verified `create`, `transition`, and `outbox-attempt` durability. The ambiguous attempt remained `awaitingReconciliation`, attempt count stayed one, and deliverable duplicates stayed zero.
- Command: `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codexguardian-swift-cache CLANG_MODULE_CACHE_PATH=/tmp/codexguardian-swift-cache ./script/test_journal_crash_replay.sh`.
- Boundary: this proves three committed edges. It does not yet inject death inside every SQLite transaction, migration, receipt, ACK, hard-restart phase, disk-full path, or permission-loss path.
