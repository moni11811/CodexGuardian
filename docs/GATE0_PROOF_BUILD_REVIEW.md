# Gate 0 Proof Build Review

## Outcome status

**PARTIAL.** The independent client, exact-thread protocol, idempotency fence,
three-phase coordinator, and installed app-server handshake work. A real Codex
task was not created or resumed, so same-Desktop continuation is not proven.

## Direct evidence passed

- Static regression failed before each missing layer: protocol, coordinator,
  then process transport.
- Standalone Swift proof compiles the production sources directly.
- Fake process app-server proves initialize -> resume -> read -> start -> exact
  completion.
- Deterministic `clientUserMessageId` suppresses an already-recorded recovery
  turn before resend.
- A server-initiated JSON-RPC request with the same numeric id cannot be
  mistaken for the client's response; the request remains queued for handling.
- A fresh installed Codex app-server process completes initialize/initialized.
- Production Codex Desktop process and current task are not restarted.

Passing proof command:

```sh
script/test_gate0_recovery_harness.sh
# PASS: Gate 0 coordinator, process transport, and installed app-server handshake
```

The focused harness compiles the three production Swift sources directly and
runs their protocol, coordinator, fake-process, collision, and installed-binary
checks. The full SwiftPM test bundle did not run: the shared `.build` link failed
because `GRDB.build/NSNumber.swift.o` changed during linking. This is not counted
as a pass and was not retried unchanged.

## Not proven

- A real `thread/resume`, `thread/read`, or `turn/start` against user task data.
- The resumed task appearing in the same Codex Desktop window.
- Restart, multi-task quiet gating, approval continuation, or three-party
  reconciliation after process death.
- Exactly-once delivery across an ambiguous crash after send but before readback.

No real task was created because that would be a user-visible Codex task and
was not separately authorized for this proof.

## Repository findings

- Existing WebSocket code only frames RFC 6455; it does not implement Codex
  app-server JSON-RPC.
- Existing Desktop-control policy requires a Desktop child process and Unix
  socket. The new stdio transport is independent of that path.
- Recovery now has separate protocol, coordinator, and transport layers so the
  next live proof can replace only the transport boundary.

## Installed binary findings

Capability inspection plus an isolated initialize handshake. No daemon, proxy,
Desktop task, or Codex state was stopped, restarted, or changed.

- Installed executable: `/Applications/ChatGPT.app/Contents/Resources/codex`.
- Version: `codex-cli 0.146.0-alpha.9.2`.
- `codex app-server --help`: supports `daemon`, `proxy`, and `generate-json-schema`; `--listen` accepts `stdio://` (default), `unix://`, `unix://PATH`, `ws://IP:PORT`, and `off`.
- `codex app-server daemon --help`: exposes `bootstrap`, `start`, `restart`, `stop`, and `version`. Presence only; none was invoked.
- `codex app-server proxy --help`: supports `--sock <SOCKET_PATH>` for a Unix-domain control socket. Presence only; no connection attempted.
- `codex app-server generate-json-schema --help`: supports `--out <DIR>` and `--experimental`. Experimental schema generation completed into disposable `/tmp/codex-schema.nQ4UMV`.
- Generated schema confirms request methods `thread/start`, `thread/resume`, `thread/read`, and `turn/start`; it also documents `turn/started` notification.
- `TurnStartParams` requires `input` and `threadId`; it accepts nullable `clientUserMessageId`. `TurnSteerParams` also accepts nullable `clientUserMessageId`.
- `codex resume --help`: CLI resume accepts a session id/name and optional prompt. This is separate from app-server `thread/resume`; it was not run.

Commands and compact output:

```sh
command -v codex; codex --version; codex app-server --help
# /Applications/ChatGPT.app/Contents/Resources/codex
# codex-cli 0.146.0-alpha.9.2
# commands: daemon, proxy, generate-ts, generate-json-schema
# --listen: stdio://, unix://, unix://PATH, ws://IP:PORT, off

codex app-server daemon --help
# commands include bootstrap, start, restart, stop, version

codex app-server proxy --help
# --sock <SOCKET_PATH>

codex app-server generate-json-schema --experimental --out /tmp/codex-schema.nQ4UMV
rg -n -i 'turn/start|clientUserMessageId|thread/resume|thread/start|thread/read' /tmp/codex-schema.nQ4UMV
# confirms all listed methods and clientUserMessageId in TurnStartParams/TurnSteerParams

codex resume --help
# supports [SESSION_ID] [PROMPT]
```

Evidence boundary: installed stdio app-server process and handshake are live.
Exact-task operations remain fixture-proven only; Desktop task recovery remains
unproven.
