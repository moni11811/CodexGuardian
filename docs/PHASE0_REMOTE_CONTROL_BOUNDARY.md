# Phase 0 Remote-Control Boundary

Date: 2026-07-27

Review findings append below.

## 2026-07-27 local bundled-CLI review

### Evidence (read-only)

| Surface | Fresh local evidence | Meaning |
| --- | --- | --- |
| Desktop child | PID `22468`, parent Desktop PID `22091`; command is bundled `codex -c features.code_mode_host=true app-server --analytics-default-enabled` | Ephemeral Desktop-owned child. It uses the default `stdio://` transport; no explicit `--listen unix://…` endpoint. |
| Guardian live probe | `guardianctl codex-control` revalidated Desktop PID/start identity, selected child PID `22468`, and returned `unavailable:noSupportedControlListener` | Read-only discovery works. Inventory, UI synchronization, and correlated persistence remain explicitly unavailable/false. |
| Desktop child file descriptors | Unix descriptors are anonymous peer pipes/sockets only; no pathname listener appears in the child descriptor list | Internal Desktop IPC. Not an advertised external app-server endpoint. |
| `~/.codex/ipc/ipc.sock` | Private Desktop socket exists | Ownership/existence alone does not establish supported app-server semantics. The prior official proxy probe against it initialized but returned no semantic response; do not use it for Guardian control. |
| `codex app-server` | Help exposes a separately launched app-server with `--listen stdio://` default and explicit `unix://` / WebSocket choices | This can create a standalone app-server listener. It is not proof of attachment to the already-running Desktop task/session. |
| `codex app-server daemon` | Help exposes `bootstrap`, `start`, `restart`, `enable-remote-control`, `disable-remote-control`, and `stop` | Durable managed daemon for SSH-driven use. It is a separate lifecycle/control plane, not the current Desktop child. No daemon command was invoked. |
| `codex remote-control` | Help exposes `start`, `stop`, and `pair`; describes an app-server daemon with remote control enabled | Separate experimental managed-daemon pairing path. It may be useful for a future Guardian-controlled daemon, but cannot prove or mutate an existing Desktop task. No pairing/start/stop command was invoked. |

### Safe conclusion

No supported, attachable **same-Desktop** app-server listener is present in the current installed mode. The Desktop child is stdio-owned; private pipes and `ipc.sock` must not be treated as a Guardian control transport.

Allowed Phase 0 state: discover and attest the signed Desktop process; keep Desktop task inventory, prompt delivery, restart continuation, and phone mutation capability **disabled**.

Future daemon/remote-control work must be labeled as a new daemon session, with separate pairing, authorization, durable journal, and explicit non-equivalence to the live Desktop task. It cannot close Gate 0 without an official supported same-Desktop semantic listener plus live read/write correlation proof.
