# Security and privacy

Codex Guardian can observe recovery metadata and request actions affecting Codex. Treat it as a local control-plane component, not an ordinary menu-bar decoration.

## Report a vulnerability

Use GitHub’s private vulnerability reporting feature for this repository. Do not open a public issue for a security problem.

Include only the minimum reproduction details. Remove:

- passwords and access tokens
- API keys and private keys
- private prompts or source code
- personal filesystem paths
- raw rollout, recovery, database, or launchd dumps
- pairing codes and device credentials

If a secret was exposed, revoke or rotate it before writing the report.

## Trust boundaries

- The macOS app, MCP helper, CLI, and daemon run as the signed-in user.
- Local clients authenticate to the daemon with separate random credentials.
- The daemon socket and state directory are user-only.
- Guardian validates the expected daemon executable for local IPC.
- Codex Desktop discovery checks the expected bundle identifier, signing identity, executable path, PID, and process-start identity before destructive control.
- A fresh origin UUID binds recovery to one exact local Codex task.
- Unknown or incomplete evidence disables automatic destructive action.
- Local AI may draft a continuation prompt. It never decides whether a task is safe, whether a restart is allowed, or whether recovery succeeded.

## Stored data

Guardian stores durable operational data under:

```text
~/Library/Application Support/CodexGuardian/
```

This can include operation IDs, task IDs, recovery state, timestamps, delivery receipts, short sanitized context snapshots, and encrypted outbox payloads. It should still be treated as private.

Local client credentials live under `credentials/`. Never publish or copy them into the repository. The installer preserves existing credentials during updates.

Backups and uninstalled state may remain under:

```text
~/Library/Application Support/CodexGuardian-Backups/
~/Library/Application Support/CodexGuardian-Uninstalled/
```

Review those folders before sharing diagnostic archives.

## Local model privacy

On supported macOS versions, Guardian can use Apple Foundation Models on device to draft a concise hard-recovery continuation. Input is bounded and common secret/path patterns are removed first. The result is advisory text only.

Redaction is defense in depth, not a guarantee that arbitrary sensitive prose can always be recognized. Do not place credentials in recovery prompts.

## Remote and phone status

Remote TLS, pairing, capability, replay, and rate-limit foundations exist in source. The remote listener is disabled by default. The iPhone client is experimental, and production prompt/restart mutations are not connected. Do not expose the daemon directly to the public internet or advertise the phone path as production-ready.

Use a trusted private network when developing remote features. Pairing invitations and pinned identities are credentials.

## Hard-restart safety

Guardian must not infer safety from silence, a running PID, copied text, or a successful app launch. Automatic restart requires fresh, complete, supported, non-conflicting state for every relevant task plus an exact active recovery heartbeat.

Current Codex Desktop control cannot prove the complete global inventory, so unattended hard restart is disabled in the production UI. Local Force Restart still requires an armed exact-task continuation and explicit confirmation.

## Public repository check

Before committing or pushing, run:

```bash
./script/check_public_repo.sh
git diff --check
```

The checker rejects common credential formats, private-key files, `.env` files, and personal absolute paths. It cannot detect every secret. Manually inspect all tracked and untracked files, generated archives, screenshots, logs, databases, and configuration before publishing.

Never commit:

- `.env` files
- `*.pem`, `*.p12`, or private `*.key` files
- Guardian state databases or credentials
- Codex rollout logs
- `~/.codex/config.toml`
- local build products
- personal screenshots or diagnostic captures

## Supported security posture

The source build uses ad-hoc local signing. Public binary distribution is not yet supported. A future downloadable release must add Developer ID signing, notarization, hardened-runtime and entitlement review, checksums, provenance, and a documented security-update process.
