# Technical setup

This guide covers local source builds, production installation, MCP registration, health checks, updates, and removal.

## Requirements

- macOS 14 or newer
- Xcode command-line tools with Swift 6
- Codex Desktop
- Codex CLI bundled with or trusted by Codex Desktop
- ImageMagick executable at `/usr/local/bin/magick` for icon generation
- An Apple-silicon or Intel Mac supported by the installed Swift toolchain

Apple Foundation Models are optional. Smart local prompt drafting is used only on macOS 26 or newer when the on-device model is available.

Check the main dependencies:

```bash
swift --version
xcode-select -p
/usr/local/bin/magick -version
```

## Source layout

| Path | Purpose |
| --- | --- |
| `Sources/CodexGuardian` | macOS menu app and dashboard |
| `Sources/GuardianDaemon` | always-on local recovery daemon |
| `Sources/CodexGuardianMCP` | MCP server used by Codex |
| `Sources/GuardianCLI` | local health and process inspection tool |
| `Sources/GuardianClient` | authenticated local daemon client |
| `Sources/GuardianCore` | journal, policies, recovery state, Codex adapters |
| `Sources/GuardianPhoneCore` | shared phone protocol and projections |
| `Phone` | experimental iPhone app |
| `Benchmarks/GuardianBench` | deterministic public policy benchmark |
| `script` | build, install, verification, and safety scripts |

## Build from source

Run the complete Swift test suite:

```bash
swift test
```

Build and open a debug app:

```bash
./script/build_and_run.sh
```

Other development modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
./script/build_and_run.sh --build-only
```

`--build-only` does not stop the currently running Guardian app. Other run modes replace the development app process.

Build a release bundle without installing it:

```bash
CODEX_GUARDIAN_BUILD_CONFIGURATION=release ./script/build_and_run.sh --build-only
```

Artifacts are written under `dist/`. They are generated files and should not be committed.

## Production installation

Run:

```bash
./script/install_production.sh
./script/test_production_install.sh
```

The installer:

1. Builds a release configuration.
2. Stages the complete app bundle.
3. Ad-hoc signs the app and embedded executables for local use.
4. Preserves existing Guardian state and credentials.
5. Replaces the installed app transactionally.
6. Installs per-user launchd jobs for the daemon and menu app.
7. Starts both services.
8. Calls `guardianctl` to prove authenticated daemon IPC.
9. Restores the previous bundle and launchd configuration if activation fails.

Installed components:

```text
/Applications/Codex Guardian.app
  Contents/MacOS/CodexGuardian
  Contents/SharedSupport/codex-guardian-mcp
  Contents/SharedSupport/guardian-daemon
  Contents/SharedSupport/guardianctl
```

Per-user launchd files:

```text
~/Library/LaunchAgents/com.moni.codexguardian.plist
~/Library/LaunchAgents/com.moni.codexguardian.daemon.plist
```

Runtime state:

```text
~/Library/Application Support/CodexGuardian/
  guardian.sqlite
  guardian.sqlite-shm
  guardian.sqlite-wal
  guardian.sock
  credentials/
```

The state directory is mode `0700`. Credential files are 32 random bytes with mode `0600`. Launch jobs start through a clean environment containing only `HOME` and a minimal system `PATH`, preventing unrelated shell tokens from reaching Guardian processes.

Failed and previous bundles are retained under:

```text
~/Library/Application Support/CodexGuardian-Backups/
```

## Register the MCP server

Add this exact block to `~/.codex/config.toml`:

```toml
[mcp_servers.codex_guardian]
command = "/Applications/Codex Guardian.app/Contents/SharedSupport/codex-guardian-mcp"
```

Restart Codex once after adding or changing the MCP entry. Registration alone is not proof. Make a live `guardian_status` call.

Expected tools:

| Tool | Purpose |
| --- | --- |
| `guardian_status` | Read daemon generation and durable operation count; never restarts Codex |
| `prepare_recovery` | Resolve the exact current task for direct native same-task queuing |
| `recover_agent` | Queue Guardian-owned idempotent native recovery through the always-on app |
| `prepare_restart` | Prepare an exact-task heartbeat before any hard restart request |
| `restart_codex` | Queue a gated hard-restart request; fails closed without a verified heartbeat |
| `recovery_tick` | Let the recovery heartbeat wait before restart or continue after relaunch |
| `ack_recovery` | Close a delivered Guardian-owned native or hard-recovery operation |

Every recovery call needs a fresh UUID placed in the originating task immediately before the MCP call. Guardian finds that UUID in the local Codex rollout and binds it to the exact task. Reusing a UUID with different data fails closed.

## Preferred native recovery

Use `prepare_recovery` while Codex can still call tools:

```text
prepare_recovery(
  origin_token: "FRESH-UUID",
  recovery_prompt: "Inspect current state, change the failed route, and continue."
)
```

Immediately pass the returned `thread_id` and `recovery_prompt` to Codex’s native `codex_app__send_message_to_thread` tool, then end the current turn. This direct queue path does not restart Codex and does not create a Guardian operation to acknowledge.

`recover_agent` is the Guardian-owned alternative. It persists an idempotent request, uses the bundled app-server transport, records an exact delivery receipt, and waits for `ack_recovery` after meaningful progress. If delivery becomes uncertain, it blocks duplicate sends and requires reconciliation.

## Hard recovery contract

Hard restart is a last resort. The required order is:

1. Generate a fresh UUID in the exact task.
2. Call `prepare_restart`.
3. Create the returned ACTIVE one-minute Codex heartbeat against the returned task ID.
4. Call `restart_codex` with the same UUID and heartbeat automation ID.
5. End the task turn.
6. The heartbeat calls `recovery_tick` until it receives `continue`.
7. After meaningful recovered progress, delete the heartbeat automation.
8. Call `ack_recovery` with the same UUID.

Guardian rejects missing, paused, malformed, wrong-task, or changed heartbeats. It ignores only the verified recovery-heartbeat turn. Any real resumed work in that task blocks restart again. Unknown task state, incomplete scans, unsupported control, stale evidence, conflicting evidence, or unrelated work also blocks automatic restart.

Current production boundary: Guardian can arm, journal, verify, and quiet-gate hard recovery, but unattended Desktop termination remains disabled because authoritative live Codex Desktop control and complete global task inventory are not proven. The dashboard reports this as **Automatic restart unavailable**. Do not describe hard restart as production-complete until that boundary is removed and proven live.

## Local health checks

Verify the installed bundle and services:

```bash
./script/test_production_install.sh
```

Call the installed daemon directly:

```bash
"/Applications/Codex Guardian.app/Contents/SharedSupport/guardianctl"
```

Inspect trusted Codex process selection:

```bash
"/Applications/Codex Guardian.app/Contents/SharedSupport/guardianctl" codex-process
```

Inspect the current Desktop control boundary:

```bash
"/Applications/Codex Guardian.app/Contents/SharedSupport/guardianctl" codex-control
```

Check launchd without printing its full inherited environment:

```bash
launchctl print "gui/$(id -u)/com.moni.codexguardian.daemon" | grep -E '^\s*(state =|pid =|last exit code =|runs =)'
launchctl print "gui/$(id -u)/com.moni.codexguardian" | grep -E '^\s*(state =|pid =|last exit code =|runs =)'
```

Run the MCP protocol smoke test against the installed binaries:

```bash
CODEX_GUARDIAN_MCP_BINARY="/Applications/Codex Guardian.app/Contents/SharedSupport/codex-guardian-mcp" \
CODEX_GUARDIAN_DAEMON_BINARY="/Applications/Codex Guardian.app/Contents/SharedSupport/guardian-daemon" \
./script/test_mcp.sh
```

## Update

Pull or download the new source, review it, then run the same transactional installer:

```bash
./script/install_production.sh
./script/test_production_install.sh
```

State and credentials are preserved. If activation fails, the installer restores the prior bundle. Do not delete backup folders until the new version has been proven in normal use.

## Uninstall

Archive the app and launchd jobs while preserving state:

```bash
./script/uninstall_production.sh
```

Archive state too:

```bash
./script/uninstall_production.sh --purge-state
```

“Purge” is recoverable here: files are moved under `~/Library/Application Support/CodexGuardian-Uninstalled/`, not permanently erased.

Remove the `[mcp_servers.codex_guardian]` block from `~/.codex/config.toml`, then restart Codex.

## Signing and distribution

The local installer uses ad-hoc signing. That is suitable for one local machine. Public downloadable app bundles require a stable bundle version, Developer ID signing, hardened runtime review, notarization, release checksums, and a tested update story. None is claimed by this repository yet.
