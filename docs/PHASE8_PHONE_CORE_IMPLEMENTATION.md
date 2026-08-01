# Phase 8 Phone Core

## Bug theory

A phone controller can lie about safety when local presentation state is allowed to imply server execution. A queued command is not an applied command. A destructive action is not safe unless its impact snapshot is complete, current, and explicitly known. Reconnect gaps invalidate incremental state. Offline retries must remain one logical command. Push notifications must carry no task, prompt, project, or result content.

The first implementation step is a pure, cross-platform Swift state layer with these invariants enforced in value types. It has no UI, sockets, credentials, or dependency on GuardianCore.

## Red-first evidence

Tests were added before production source. The first focused build must fail because `GuardianPhoneCore` does not yet exist. The failure is captured in this document before implementation.

## Scope

- iOS 17 package support and a standalone `GuardianPhoneCore` library.
- Honest command lifecycle presentation.
- Fail-closed destructive-action authorization.
- Opaque notification validation.
- Projection continuity decisions.
- Capability actionability decisions.
- Offline command deduplication.

Out of scope: network transport, pairing, persistence engine, notifications transport, and UI.
