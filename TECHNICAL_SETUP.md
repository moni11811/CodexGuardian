# Technical Setup

## Requirements

- macOS 14 or newer
- Xcode command-line tools
- Codex desktop and Codex CLI

## Build and verify

```bash
./script/build_and_run.sh --verify
./script/test_mcp.sh
```

Artifacts are written to `dist/`.

## Production installation

```bash
./script/install_production.sh
./script/test_production_install.sh
```

This installs `/Applications/Codex Guardian.app`, embeds the MCP helper, ad-hoc signs the local bundle, and registers a per-user LaunchAgent.

Add the installed helper to `~/.codex/config.toml`:

```toml
[mcp_servers.codex_guardian]
command = "/Applications/Codex Guardian.app/Contents/SharedSupport/codex-guardian-mcp"
```

Restart Codex once to load the MCP server. Keep Codex Guardian running in the menu bar.

Preferred same-task recovery:

```text
prepare_recovery(
  origin_token: "GENERATE-A-FRESH-UUID-FOR-EACH-CALL",
  recovery_prompt: "Inspect current state, change route, and continue."
)
```

The MCP result contains `thread_id` and `recovery_prompt`. Codex must immediately pass them to its native `codex_app__send_message_to_thread` tool. This queues a follow-up in the exact desktop task without restarting the app.

Hard restart:

```text
prepare_restart(
  origin_token: "GENERATE-A-FRESH-UUID-FOR-EACH-CALL"
)

# Create the returned exact-thread ACTIVE heartbeat with Codex's
# automation tool. Then use its automation id:

restart_codex(
  origin_token: "GENERATE-A-FRESH-UUID-FOR-EACH-CALL",
  continuation_automation_id: "AUTOMATION-ID-FROM-CODEX",
  recovery_prompt: "Continue this task. The previous tool call became stuck. Do not repeat the unchanged method; inspect current state and use a fallback.",
  delay_seconds: 2
)
```

Guardian locates the rollout containing `origin_token` and extracts the exact task ID. `prepare_restart` returns a heartbeat prompt for that task. Codex creates the heartbeat through its native automation tool. `restart_codex` reads the saved automation and fails closed unless it is active, targets the exact task, and contains the same UUID.

Hard restart requests remain on disk while Guardian reads bounded rollout headers/tails. It scans every rollout changed since the current Codex process launched, with at least a 12-hour lookback. Any non-terminal task blocks restart. More than 200 candidates, malformed state, or scanner failure also blocks restart. The native heartbeat must call `recovery_tick` once before Guardian permits the restart. This proves Codex registered it. Guardian verifies it again immediately before stopping Codex. Once every observed task is terminal and no rollout changes for 15 seconds, Guardian claims the exact queue snapshot, checks activity again, restarts Codex once, and opens `codex://threads/<TASK_ID>`. After relaunch, one heartbeat run receives the on-device recovery prompt; overlapping runs wait. The claim remains until the recovered task deletes or pauses the heartbeat and calls `ack_recovery`. Guardian never launches detached `codex exec resume` workers. If the origin or heartbeat cannot be proven, Codex is not restarted.

The menu-bar **Force Restart Codex Now** action bypasses this gate only after a person explicitly clicks it.

## Smart recovery

On macOS 26 or newer, Guardian uses Apple's Foundation Models framework when the on-device model is available. It extracts at most 6,000 characters from the recent rollout tail, removes the origin marker and common credential/path patterns, and asks the local model for a concise continuation prompt. It falls back to `recovery_prompt` or Guardian's built-in prompt when the model is unavailable or generation fails.

The MCP client only needs to provide a fresh `origin_token`; `recovery_prompt` is optional. Apple-model prompt generation currently applies to hard restart recovery. Native same-task recovery keeps the current task context and uses the supplied or built-in prompt.

## Local signing

The installer uses ad-hoc signing for local use. Redistributable binaries require Developer ID signing and Apple notarization.
