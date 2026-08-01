# User guide

## The simple idea

Guardian watches recovery state for Codex. When a task needs help, it tries the smallest safe action first:

1. Observe and explain.
2. Continue the same task without restarting Codex.
3. Consider a hard restart only when continuation cannot work and every safety requirement is proven.

Guardian prefers waiting over guessing.

## Menu-bar shield

The shield menu shows two short lines:

- daemon status
- current recovery status

Actions:

- **Open Guardian** — opens the full dashboard.
- **Refresh** — requests a fresh daemon snapshot.
- **Force Restart…** — opens the dashboard and asks for confirmation. It works only with a previously armed exact-task recovery.
- **Quit Guardian** — closes the menu app. The launchd-supervised daemon is a separate process.

## Dashboard

The sidebar separates tasks into:

- **Attention** — waiting for you, slow, stuck, or unknown.
- **Active** — working, running, or recovering.
- **Recent** — idle and finished tasks plus recovery history.

An incomplete observer shows **Observer not ready**. That is a safety state, not a cosmetic warning: destructive automation stays disabled.

Recovery history uses these plain meanings:

| Display | Meaning |
| --- | --- |
| Prepared | Recovery intent saved |
| Safety check | Waiting for required evidence |
| Restart issued | Trusted restart side effect issued |
| Desktop started | New Codex process observed |
| Control ready | Control transport became ready |
| Task loaded | Exact task reopened |
| Continuation sent | Continuation submitted |
| Delivered | Exact delivery receipt stored |
| Monitoring | Watching recovered work |
| Waiting for you | Human action required |
| Continued | Meaningful progress acknowledged |
| Failed / Timed out / Needs review | Recovery did not safely complete |

## Normal recovery

Use normal recovery while Codex can still call tools. Guardian finds the exact requesting task, and Codex’s own desktop interface queues a continuation there. This does not restart Codex.

A good continuation prompt says what outcome remains and warns against repeating the failed method. Never include secrets.

## When Guardian waits

Waiting is correct when Guardian sees:

- another active task
- real resumed work in the requesting task
- an approval, question, permission, or login prompt
- incomplete or stale task inventory
- changed heartbeat state
- unknown Codex identity or control path
- unavailable restart authority

Do not repeatedly mint new UUIDs. One recovery request keeps one identity.

## Force Restart

Force Restart can interrupt every running Codex task. It is only for a person physically using the Mac. Guardian still requires an armed exact-task continuation and verifies it again before acting.

The current production UI does not offer unattended automatic hard restart because complete authoritative Desktop state is unavailable.

## What Guardian never uses

- clipboard paste as recovery proof
- Accessibility keystrokes to press Send
- screen pixels as recovery authority
- `codex exec resume`
- a second hidden Codex worker
- an online AI model to decide safety

## Getting help safely

Start with [Troubleshooting](TROUBLESHOOTING.md). Share only redacted status text. Never upload Guardian databases, credentials, pairing codes, Codex rollout logs, raw prompts, or complete launchd dumps.
