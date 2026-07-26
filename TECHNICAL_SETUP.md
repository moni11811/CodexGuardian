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
restart_codex(
  origin_token: "GENERATE-A-FRESH-UUID-FOR-EACH-CALL",
  recovery_prompt: "Continue this task. The previous tool call became stuck. Do not repeat the unchanged method; inspect current state and use a fallback.",
  delay_seconds: 2
)
```

Guardian locates the rollout containing `origin_token` and extracts the exact task ID. Hard restart requests are queued; Guardian restarts Codex once, opens `codex://threads/<TASK_ID>`, and copies the prompt. A hard restart cannot submit a new turn. Guardian never launches detached `codex exec resume` workers. If the origin cannot be proven, the MCP call fails without restarting Codex.

## Smart recovery

On macOS 26 or newer, Guardian uses Apple's Foundation Models framework when the on-device model is available. It extracts at most 6,000 characters from the recent rollout tail, removes the origin marker and common credential/path patterns, and asks the local model for a concise continuation prompt. It falls back to `recovery_prompt` or Guardian's built-in prompt when the model is unavailable or generation fails.

The MCP client only needs to provide a fresh `origin_token`; `recovery_prompt` is optional. Apple-model prompt generation currently applies to hard restart recovery. Native same-task recovery keeps the current task context and uses the supplied or built-in prompt.

## Local signing

The installer uses ad-hoc signing for local use. Redistributable binaries require Developer ID signing and Apple notarization.
