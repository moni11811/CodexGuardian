# Draft: Supported Codex Desktop Control Listener

Status: local draft. Open [openai/codex#25914](https://github.com/openai/codex/issues/25914) covers the same gap. No Guardian comment is published.

## Problem

Codex Desktop starts its bundled app-server on private stdio. The documented Unix control transport is not enabled. Desktop's separate private IPC socket does not accept the documented WebSocket Upgrade protocol.

Therefore an external local supervisor cannot prove that it is observing or writing the same live Desktop app-server instance. Starting another app-server is not equivalent: Desktop is not a subscriber to that second host.

## Requested capability

Expose an opt-in, supported local control listener owned by the exact app-server process used by Codex Desktop.

Required properties:

1. WebSocket-over-Unix transport documented by app-server.
2. Multiple local clients without stealing Desktop's subscription.
3. Handshake identity: Desktop bundle identity, app-server process epoch, protocol/schema version, server generation.
4. Desktop and external clients receive synchronized thread/turn status.
5. `thread/loaded/list`, `thread/read`, approvals, MCP readiness, background terminals, and active child/subagent inventory.
6. Inventory completeness flag: `complete`, `partial`, or `unavailable`.
7. `turn/start.clientUserMessageId` persists in thread items across disconnect and Desktop restart.
8. Sequence numbers or snapshot generation for gap detection and stale-command fencing.
9. Read-only capability by default; explicit authorization for write/interrupt/approval operations.
10. Local peer authentication stronger than same UID where practical.

## Acceptance proof

1. Attach read-only while Desktop remains open.
2. List the same loaded thread visible in Desktop.
3. Observe one Desktop-started turn from start to completion.
4. Disconnect/reconnect; obtain a consistent snapshot without changing Desktop state.
5. Send one uniquely identified message to a disposable thread.
6. Desktop shows that exact message in that exact thread.
7. Disconnect after send but before reply; restart Desktop; recover the same message/turn by ID without duplicate delivery.
8. Unknown schema, sequence gap, identity mismatch, or incomplete inventory fails closed.

Until this exists, Guardian keeps native same-thread delivery through Codex's own app tools and disables direct external Desktop control.

## Current production evidence — 2026-07-27

- Codex Desktop `26.721.41059` build `5848`; bundled CLI
  `0.146.0-alpha.3.1`.
- `guardianctl codex-control` attested the exact Desktop-owned child but found
  default stdio transport and no supported listener.
- Inventory, Desktop UI synchronization, and correlated exact-thread
  persistence remain unavailable/unproven.
- No detached daemon, prompt, socket mutation, or restart was used.
