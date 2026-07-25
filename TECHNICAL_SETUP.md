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

Codex can then call:

```text
restart_codex(
  origin_token: "GENERATE-A-FRESH-UUID-FOR-EACH-CALL",
  recovery_prompt: "Continue this task. The previous tool call became stuck. Do not repeat the unchanged method; inspect current state and use a fallback.",
  delay_seconds: 2
)
```

Guardian locates the rollout containing `origin_token`, extracts the exact task ID, queues concurrent recovery requests, restarts Codex once, and starts `codex exec resume <TASK_ID> <PROMPT>` for every queued task. If the origin cannot be proven, the MCP call fails without restarting Codex.

## Local signing

The installer uses ad-hoc signing for local use. Redistributable binaries require Developer ID signing and Apple notarization.
