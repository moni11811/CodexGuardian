# Privacy

Guardian is local-first. It does not include analytics or an online Guardian account. Local-first does not mean “stores nothing.”

## Data Guardian may process

- exact Codex task IDs and operation IDs
- task and recovery states
- timestamps, generations, sequence numbers, and delivery receipts
- bounded recent task context used to draft a continuation
- recovery prompts supplied by the task
- device identity and capability metadata for experimental pairing

Guardian should not receive passwords, access tokens, private keys, or unnecessary personal data.

## Local storage

Primary state is under `~/Library/Application Support/CodexGuardian/`. It includes SQLite journal files, encrypted outbox material, local client credentials, and the Unix socket.

Transactional install backups are under `~/Library/Application Support/CodexGuardian-Backups/`. Uninstall archives are under `~/Library/Application Support/CodexGuardian-Uninstalled/`.

The installer restricts runtime directories and credentials to the signed-in user. Other processes running as the same macOS user remain part of the local threat boundary.

## Apple local model

On macOS 26 or newer, Guardian may send a bounded, best-effort-redacted context excerpt to Apple Foundation Models on device. The model drafts advisory continuation text. It cannot authorize restart, mutate state, call tools, or invent a valid acknowledgement.

Pattern removal cannot guarantee recognition of every secret. Keep secrets out of task recovery prompts and source diagnostics.

## Remote and phone data

Experimental remote code uses pinned TLS, pairing identities, scoped capabilities, sequence numbers, receipts, and encrypted payloads. The listener is disabled by default. The phone app is not a shipped production controller.

Do not expose the development listener to the public internet or place private content in push notifications, screenshots, pairing QR codes, or bug reports.

## Retention and deletion

Guardian keeps durable data so it can distinguish a lost reply from a lost operation and avoid duplicate continuation. ACK and retention policies should remove operation key material when an operation is complete, but physical deletion on SSD storage and backups is best effort.

To archive the app while keeping state:

```bash
./script/uninstall_production.sh
```

To archive state too:

```bash
./script/uninstall_production.sh --purge-state
```

Review and remove the resulting archive manually only after confirming it is no longer needed. Also delete any Codex recovery heartbeat automation and remove the MCP config entry.

## Public diagnostics

Share derived status, never raw state. Database files, WAL files, credentials, pairing material, recovery logs, rollout tails, prompts, and complete process environments are private.
