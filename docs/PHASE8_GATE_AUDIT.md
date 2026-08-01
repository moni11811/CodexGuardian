# Phase 8 gate audit

Status: source progress; exit not proven.

| Requirement | Current evidence | Verdict |
| --- | --- | --- |
| Pending is not applied | `GuardianPhoneCoreSafetyTests` and durable outcome codec/history | Proven in unit tests |
| Fresh destructive impact | `DestructiveActionPolicy` tests and confirmation sheet | Proven as local policy; remote provider absent |
| Opaque notifications | `OpaqueNotification` regression | Payload type proven; delivery absent |
| Attention / Active / Recent | Native SwiftUI mapper and generic iOS test build | Compiles; runtime/UI not executed |
| Pair and observe | Keychain, signed QR flow, pinned TLS, observe codec/client | Unit/integration green; live device absent |
| Network reconnect | Durable exact-frame retry, event replay/full snapshot, single-flight, cancellation, transient-only backoff | Deterministic tests green; live LAN/VPN drill absent |
| Prompt / steer / interrupt / approval / repair / recovery / cancel | Protocol capabilities exist | Production Mac semantic adapters absent; phone controls disabled |
| Impact / diff / checkpoint | Impact policy/UI shell exists | Authoritative remote impact provider and diff/checkpoint transport absent |
| Background reconnect | Active-scene resume supervisor exists | Optional BG refresh/push and device lifecycle proof absent |
| Same Mac/phone operation history | Bounded recovery and per-device command history flow through Mac snapshot/router, phone codec/session, mapper, and Recent UI | Source parity proven; live two-device drill absent |
| No terminal/screen sharing | Intended architecture | End-to-end recovery drill absent |

Current automated evidence:

- Full Swift package run: 328 tests in 12 suites pass.
- Generic iOS Simulator `build-for-testing` passes.
- Xcode reports zero installed Simulators, so app tests are compile-only.

Next source gate: implement the production semantic Desktop mutation adapter,
typed phone commands, and authoritative impact/diff/checkpoint providers.
Mutation controls stay hidden until exact-task idempotency, reconciliation, and
authorization evidence are live.
