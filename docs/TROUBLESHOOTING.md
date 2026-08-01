# Troubleshooting

Use one changed, evidence-backed action at a time. Do not loop the same restart or recovery call.

## Quick checks

```bash
./script/test_production_install.sh
"/Applications/Codex Guardian.app/Contents/SharedSupport/guardianctl"
```

If MCP tools are missing, confirm the config entry, restart Codex once, then make a real `guardian_status` call. A listed tool is not live proof.

## Symptoms

| Message or symptom | Meaning | Safe next action |
| --- | --- | --- |
| `Daemon: unavailable` | Menu app cannot authenticate or connect to expected daemon | Run production verifier. Check the daemon launchd state. Reinstall transactionally if binary/plist is missing. |
| `daemon unavailable or untrusted` | Socket, credential, peer path, or daemon health check failed | Verify owner-only state and installed paths. Do not loosen permissions. |
| `Observer not ready` / `observer incomplete` | Complete task inventory is unavailable | Refresh once. Continue non-destructive work. Do not force automatic restart. |
| `Automatic restart unavailable` | Supported Desktop-wide control proof is missing | Use native same-task recovery. Use local Force Restart only with an armed continuation and accepted risk. |
| `no supported control listener` | Desktop app-server is private stdio, not an external supported listener | Expected current limitation. Do not launch a detached app-server and call it Desktop proof. |
| `origin_token is required` | MCP call omitted the fresh UUID | Generate one in the originating task and call once. |
| origin/task cannot be resolved | UUID was absent, stale, duplicated, or outside the exact rollout | Put a new UUID in the current task immediately before one changed call. |
| `duplicate send blocked` / native recovery uncertain | Guardian cannot prove whether a message was accepted | Do not mint a new UUID. Let reconciliation inspect the exact client message ID. |
| `Recovery request was not found` after direct `prepare_recovery` | Direct native queuing creates no Guardian-owned ACK record | Do not ACK this path. The same-task delegation receipt is its completion proof. |
| `continuation not armed` | Hard request lacks a verified exact-task heartbeat | Start again from `prepare_restart`; do not restart Codex first. |
| heartbeat not registered / changed | Heartbeat has not called `recovery_tick`, is paused, malformed, or no longer matches | Restore one exact ACTIVE heartbeat. Delete stale copies. |
| `recovery_tick` returns `waiting` | Restart has not safely completed | End the heartbeat run. Do not keep it busy or call again in a tight loop. |
| waiting for active tasks / quiet period | Another task or fresh activity blocks the global boundary | Let real work finish. Do not bypass automatically. |
| authority unavailable / transferred | This process does not own destructive authority | Keep recovery non-destructive. Restart/reinstall Guardian only if its services are actually broken. |
| activation failed | New install could not start and pass daemon health | Installer restores the prior bundle. Read the named activation stage and change the diagnosis before retrying. |
| app missing from `/Applications` | Production install did not complete | Run installer from source and verify. Guardian resolves Codex by trusted bundle identity; it does not look for `ChatGPT.app`. |

## Launchd status

Print only bounded service fields. Full launchctl output may reveal inherited environment values.

```bash
launchctl print "gui/$(id -u)/com.moni.codexguardian.daemon" \
  | grep -E '^\s*(state =|pid =|last exit code =|runs =)'

launchctl print "gui/$(id -u)/com.moni.codexguardian" \
  | grep -E '^\s*(state =|pid =|last exit code =|runs =)'
```

Both should normally show `state = running` and a PID. Guardian launch jobs deliberately use a clean environment so unrelated token variables do not reach the processes.

## MCP smoke test

```bash
CODEX_GUARDIAN_MCP_BINARY="/Applications/Codex Guardian.app/Contents/SharedSupport/codex-guardian-mcp" \
CODEX_GUARDIAN_DAEMON_BINARY="/Applications/Codex Guardian.app/Contents/SharedSupport/guardian-daemon" \
./script/test_mcp.sh
```

This proves MCP framing and daemon startup against fixtures. A real `guardian_status` or disposable native continuation is separate live proof.

## Safe cleanup

- Delete stale Codex recovery heartbeat automations. Pausing is not cleanup.
- Do not hand-edit `guardian.sqlite`, WAL files, queue files, or credentials.
- Reinstall preserves state and rolls back failed activation.
- Uninstall archives runtime files; `--purge-state` archives state too.
- Keep backups until the replacement is proven.

## Diagnostic sharing

Safe summary items:

- macOS version
- Guardian commit or tag
- Codex Desktop version
- exact visible error text
- whether the bounded service state says running
- which verification command failed and its exit code

Never attach:

- Guardian SQLite/WAL or credential files
- `remote.json`, pairing codes, QR images, or Keychain exports
- Codex rollout/session logs
- private prompts, tool output, source files, or personal paths
- complete `launchctl print` output
- raw environment variables

Use GitHub private vulnerability reporting for security defects.
