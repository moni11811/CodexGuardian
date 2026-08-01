# Codex Guardian

Codex Guardian is a shield for Codex on your Mac.

When an AI task gets stuck, Guardian tries to continue the **same task** without losing its place or disturbing other work.

## What works today

- A shield app runs from the Mac menu bar.
- A private local daemon remembers recovery state, even if the menu app closes.
- Codex can call Guardian through MCP.
- Guardian can identify the exact task that requested help.
- The normal recovery path sends a continuation to that exact Codex task without restarting Codex.
- Repeated requests use a unique ID so Guardian does not send the same continuation twice.
- Unknown, incomplete, or conflicting safety evidence stops destructive automation.
- Recovery history and task state appear in the Guardian window.

## What is intentionally limited

Unattended hard restart is **not enabled in the current production UI**. Codex Desktop does not expose the complete, authoritative live-task inventory Guardian needs to prove that every other task is safe. Guardian therefore fails closed instead of guessing.

The **Force Restart…** button is a local emergency control. It still requires a previously armed exact-task continuation and a second human confirmation. It is not a general “kill Codex” button.

The iPhone project is an experimental client. Pairing and observation foundations exist, but production prompt and restart commands are not connected yet.

See [Current capabilities](docs/RECOVERY_WORKFLOWS.md#current-capabilities) for the exact support table.

## Install

You need macOS 14 or newer, Xcode command-line tools, Swift 6, and ImageMagick at `/usr/local/bin/magick`.

From this project folder:

```bash
./script/install_production.sh
./script/test_production_install.sh
```

The installer builds a release app, installs it at `/Applications/Codex Guardian.app`, starts the menu app and daemon, creates private local credentials, and rolls back to the previous app if activation fails.

Add the MCP helper to `~/.codex/config.toml`:

```toml
[mcp_servers.codex_guardian]
command = "/Applications/Codex Guardian.app/Contents/SharedSupport/codex-guardian-mcp"
```

Restart Codex once so it loads the new MCP server. You should then see Guardian tools such as `guardian_status` and `prepare_recovery`.

## Recover a task

Ask Codex to use Guardian’s native recovery. Codex should:

1. Generate a fresh UUID in the current task.
2. Call `prepare_recovery` with that UUID.
3. Send Guardian’s returned prompt to Guardian’s returned task ID using Codex’s native same-task message tool.
4. End the old turn. The queued continuation arrives in the same task automatically.

No copy, paste, Accessibility permission, fake mouse click, or detached `codex exec resume` worker is used.

## Learn more

- [User guide](docs/USER_GUIDE.md)
- [Recovery workflows and current limits](docs/RECOVERY_WORKFLOWS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Technical setup](TECHNICAL_SETUP.md)
- [Security and privacy](SECURITY.md)
- [Development and testing](docs/DEVELOPMENT.md)
- [Documentation map](docs/README.md)

## License

Codex Guardian uses the [PolyForm Noncommercial License 1.0.0](LICENSE).

You may read, use, change, and share it for permitted noncommercial purposes. Commercial use requires separate permission. This is public source, but it is **not OSI-approved open source** because commercial use is restricted.

## Project status

This is an early public project. The installed Mac app, local daemon, MCP, native exact-task continuation, durable journal, and fail-closed safety policies are implemented and tested. Automatic hard restart and production phone control remain gated by missing authoritative Codex Desktop capabilities.

Never put passwords, API keys, access tokens, private prompts, personal paths, or recovery logs in a public issue.
