# Phase 8 iPhone UI implementation

Status: native iOS 17 app implemented with production pairing and observe-only
remote transport. Mutation controls remain fail-closed.

## Bug theory

Guardian had safety primitives but no iPhone target. A remote UI built before capability, outcome, and impact-state semantics would imply that queued means applied and could expose restart without a fresh whole-system impact check.

## Implemented

- XcodeGen project using the local `GuardianPhoneCore` package product.
- One compact SwiftUI dashboard: Attention, Active, Recent.
- Root-owned `@Observable` store with an injected async service.
- Loading, disconnected, error, and ready states.
- Item-driven task detail, pairing-code sheet, and offline preview fixtures.
- Capability-disabled prompt/restart controls until a semantic Mac adapter can
  prove exact effects.
- Pending commands say **Waiting for Guardian**, never **Applied**.
- Restart requires a newly fetched complete impact snapshot, policy approval, and a separate explicit confirmation.
- Shield visuals plus accessibility labels and stable identifiers.

## Evidence boundary

Production service uses Keychain pairing, pinned TLS, signed observe, durable
reconnect, event replay, and full-snapshot reconciliation. Generic Simulator
`build-for-testing` passes. This does not prove live-device pairing/TLS,
LAN/VPN reconnect timing, background execution, mutation execution, restart,
push, or App Store readiness.

## Reproduce

```sh
cd Phone
xcodegen generate
xcodebuild -project CodexGuardianPhone.xcodeproj -scheme CodexGuardianPhone -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```
