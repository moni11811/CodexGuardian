# Codex Guardian Repository Threat Model

## Overview

Codex Guardian is a macOS recovery and control plane for Codex Desktop. This repository contains a Swift menu app, launchd daemon, MCP server, CLI, local Unix-socket client, SQLite journal/outbox, restart policy, installer, tests, an experimental iPhone target, and remote TLS/pairing foundations. The remote listener is disabled by default, phone mutation commands fail closed, and neither remote control nor the phone app is a supported production feature.

Guardian can eventually interrupt, prompt, approve, terminate, relaunch, and continue Codex tasks. Its main security invariant is fail closed: no destructive action unless client identity, origin task, target task, authority generation, complete task inventory, safe point, readiness, and delivery evidence are current and coherent.

Security-sensitive assets:

- Codex execution authority and exact task/thread identity.
- Prompts, approvals, tool activity, diffs, worktree state, and recovery context.
- SQLite journal, outbox, leases, budgets, circuits, authority fence, generations, cursors, and audit.
- Local client credentials and the Keychain-held payload parent key.
- Guardian binaries, launchd configuration, install backups, and rollback state.
- Experimental device keys, scopes, revocation state, offline commands, receipts, and push metadata.

Security objectives:

1. Only an authenticated principal may request an explicitly scoped action.
2. Requests affect only their bound origin/target task and capability.
3. Remote clients never bypass safety gates or invoke force restart; force is Mac-local and freshly confirmed.
4. Replayed, duplicated, expired, revoked, stale-generation, or sequence-gapped commands fail closed.
5. Crashes and lost acknowledgments cannot create duplicate or wrong-thread actions.
6. Untrusted content cannot become policy or model-created authority.
7. Updates cannot replace the verified install with an untrusted or partial one.

## Threat Model, Trust Boundaries, and Assumptions

### Trust boundaries

1. **Codex task to MCP.** AI-supplied JSON-RPC arguments, origin tokens, thread IDs, and prompts are untrusted. MCP stays same-origin-bound and never receives force authority.
2. **Mac clients to daemon.** Menu app, MCP, and CLI use a bounded Unix socket. The daemon currently checks peer UID plus a bearer credential. A malicious process under the same macOS user can read owner-readable credential files and impersonate a client. This is an open gap, not a strong process-authentication boundary.
3. **Daemon to persistence.** SQLite/WAL state determines side effects. Missing, corrupt, stale, conflicting, or reverted authority data blocks destructive work.
4. **Daemon to Codex Desktop.** Desktop discovery, live control, exact-thread delivery, and relaunch cross into an external application. A detached app-server or proxy is not the live Desktop task.
5. **Guardian to macOS.** Keychain, LaunchServices, process identity, code signing, launchd, ownership, and permissions count only when explicitly verified. PID or process name alone is insufficient.
6. **Installer/update boundary.** Source, dependencies, build output, staging, signing, launchd plists, backups, and rollback are supply-chain inputs.
7. **Experimental Mac-to-phone boundary.** Pairing, TLS, device identity, reconnect, offline queues, and push cross a hostile network. LAN/VPN membership is not authentication.
8. **Local model boundary.** Model summaries are untrusted advice. They never prove liveness, authorize restart, grant capability, or establish ACK.
9. **Public artifacts boundary.** Git, issues, logs, benchmarks, screenshots, and diagnostics must not leak prompts, credentials, keys, personal paths, or recovery payloads.

### Attacker capabilities

- Send arbitrary MCP input through a compromised or prompt-injected task.
- Delay, reorder, duplicate, replay, truncate, or drop future remote traffic.
- Use a formerly paired but revoked phone and cached offline commands.
- Race disconnects with ACKs; reuse old generations, sequences, nonces, IDs, or database snapshots.
- Supply malformed or oversized frames, timestamps, prompts, events, rows, and paths.
- Modify user-writable files, race symlinks, substitute binaries, or exploit unsafe install paths.
- Run an untrusted process as the same macOS user and read ordinary `0600` files owned by that user.
- Search public artifacts for committed secrets or private data.

### Assumptions and exclusions

- Root, a compromised kernel, or a compromised user login can bypass user-level controls and is outside the main boundary.
- Codex Desktop may not expose the exact primitives Guardian needs. Missing proof disables automatic restart/direct delivery; Guardian does not substitute clipboard/UI automation, TUI parsing, `codex exec resume`, or a detached app-server.
- Remote gateway and phone code exist, but production mutation and public deployment are unavailable. Remote security statements remain requirements until live-device and hostile-network proof exists.
- SSD deletion is best effort. Cryptographic erasure requires destroying the only operation-key material and preventing plaintext in logs, backups, and crashes.

## Attack Surface, Mitigations, and Attacker Stories

### Local IPC and impersonation

Local frames are length-bounded and deadline-limited. State directories use `0700`; token/database/socket files use `0600`; credential reads use `O_NOFOLLOW` plus owner/type/mode/length checks. Commands carry version, client ID, generation, deadline, origin/target binding, role, and capabilities. MCP cannot cross threads or force restart. The authoritative daemon requires a durable authority permit.

Open gap: same UID plus a file bearer token does not authenticate an install-bound process. The daemon verifies UID but not the connecting executable or signing identity; ad-hoc signing is not a stable designated requirement. Before destructive daemon actions activate, use a launchd XPC/Mach audit-token boundary with a pinned signing requirement, or equivalent per-client isolation. Keep separate roles and never grant MCP/remote `forceRestart`.

Attacker story: a same-user script reads `mcp.token` and submits a valid hard-recovery request using the fixed MCP client ID. Present checks cannot distinguish it from MCP.

### Confused deputy and cross-thread control

Bind every request to authenticated client, origin task, target task, operation ID, action, generation, deadline, and capabilities. MCP proves its current origin and targets only that task. Unknown or conflicting identity blocks before an operation or side effect is created.

Attacker story: a prompt-injected task supplies another task's ID and asks Guardian to approve or restart it. Origin binding rejects it.

### Replay, duplicates, and ambiguous ACK

Future remote commands require a device-scoped monotonic sequence, unique nonce/idempotency key, deadline, revocation epoch, expected server generation, capability scope, and authenticated signature/channel. The server journals acceptance before side effects and returns a receipt binding device, operation, digest, generation, sequence, and state. Identical duplicates return the same receipt; an ID reused with different content is rejected. Gaps, lost ACKs, or generation change require snapshot reconciliation, never blind resend.

Attacker story: a revoked phone replays an old signed restart packet. Its old revocation epoch is rejected before enqueue and again before side effect.

### Unsafe restart and authority races

Existing defenses include daemon generations, leases, budgets, circuits, process identity, an authority fence, complete-inventory checks, a serialized final-drain barrier, and crash injection. Shadow mode rejects authority. Automatic hard restart is currently disabled because the live Desktop adapter cannot prove an atomic boundary.

Immediately before termination, compare-and-swap Desktop PID/start identity/signature/bundle URL, server generation, inventory, and final sequence under one serialized boundary. Partial inventory or missing quiesce/CAS blocks automation. Force remains freshly confirmed on the local Mac and is never remote.

Attacker story: a task starts after snapshot but before kill. Final drain observes it and blocks; without that primitive, automatic restart remains off.

### Persistent state and secrets

GRDB transactions, WAL full synchronization, restrictive modes, typed migrations, corrupt-row isolation, leases, append-only authority events, and crash tests reduce ambiguity. Outbox payloads use per-operation AES-GCM keys wrapped by a Keychain parent key and authenticate the operation ID.

Missing/corrupt/reverted fence, generation, manifest, revocation, or receipt blocks. Destroy wrapped operation-key material after ACK, checkpoint/truncate WAL, keep plaintext out of logs/backups, and document SSD deletion limits.

Attacker story: an old database copy is restored. Monotonic-state rollback detection or forced re-pairing must prevent revived devices and replayed operations.

### Pairing and remote transport

Before opening any listener, use mutually authenticated forward-secure transport and pin the Mac identity during an authenticated, short-lived, single-use QR ceremony. Use a hardware-backed phone key when available. QR data must not become a reusable logged bearer secret. The Mac locally confirms the device and scopes. Defaults are observe plus policy-approved non-destructive control; no remote force scope exists.

Persist device public key, scopes, pair/revoke epochs, last sequence, and audit. Check revocation at receipt and immediately before side effects. Rotate keys, expire sessions, rate-limit auth/destructive requests, avoid public bind by default, and keep private data out of push payloads.

Attacker story: a photographed stale QR is reused. Expired/consumed nonce and absent local confirmation reject enrollment.

### Parser and denial of service

Fuzz local and remote decoders. Cap frame/decompressed size, nesting, collections, prompt/diff size, retained offline work, connections, and work per client. Add auth throttles, restart budgets, cooldown, dead letters, and bounded audit retention. Exhaustion never weakens checks or makes defaults permissive.

### Installer and supply chain

Installation rejects broad/symlinked paths, stages near destination, verifies before activation, keeps a `0700` backup, probes the daemon, and rolls back failed activation. Public scans detect several secret filenames, keys, tokens, and personal paths.

Ad-hoc signing does not authenticate a publisher. External release requires pinned dependencies, SBOM/provenance, Developer ID signing, hardened runtime, notarization, designated-requirement and digest verification, migration rollback proof, and secret scans over source, package, and relevant history. Updater authority stays separate from command authority.

### Codex/model content and privacy

Treat Codex events, tool output, diffs, files, logs, and model text as data. Unknown protocol versions are observe-only. Nothing in these inputs becomes shell or policy. Local-model context is minimal, redacted, bounded, and on device; output is labeled advisory and limited to diagnostics or continuation drafts.

Extend privacy scanning to packages, generated docs, Git history, QR material, SQLite/WAL fixtures, and system logs. Benchmarks use synthetic fixtures. Diagnostics are explicit, redacted, and opt-in.

## Severity Calibration

**Critical:** unauthenticated network control; pairing bypass; persistent update compromise; scalable key/authorization bypass; any remote force or deliberate safety-gate bypass.

**High:** replay/revocation/sequence/ACK failure causing wrong or duplicate action; same-user impersonation reaching destructive daemon work; authority/generation/process/safe-point bypass; private prompt/key/credential leakage; unverified binary activation or authorization rollback.

**Medium:** authenticated denial of service, audit loss, or readiness spoofing without destructive authority; optional component creating indefinite wait; non-destructive metadata access beyond scope; isolated operation corruption while authority remains fail closed.

**Low:** bounded local availability loss with safe recovery; non-sensitive aggregate status disclosure; UI labeling bugs that cannot affect authorization or side effects.

Unknown evidence, missing inventory, stale generation, unavailable atomic boundary, failed authentication, and failed revocation checks always block the affected destructive action.

Repository: codex-security-target/v1:sha256:419f6cfe63deabf554fc57902ce64310ae039e89558e2e7b9e3bd8cdcb671bd0
Version: codex-security-snapshot/v1:sha256:0e542566809a5f24b5c0232a5c7c95dd99cb9bf819277dbcdd4eb0fd5bbf2e90
