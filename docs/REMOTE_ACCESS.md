# Remote and iPhone status

Remote access is experimental and disabled by default.

## Implemented foundations

- iOS 17 SwiftUI target
- QR/pairing-code decoding
- Keychain device identity storage
- pinned TLS exchange
- signed requests and scoped capabilities
- replay sequence and generation handling
- reconnect and full-snapshot reconciliation
- remote rate limits and bounded wire frames
- observe projections and recovery/command history UI

## Not production-ready

- no distributed iPhone app
- no live-device product proof
- no documented supported server provisioning flow
- no production prompt, steer, approval, or restart mutation from the phone service
- no public-internet deployment support
- no App Store/TestFlight, background, notification, or VPN reliability claim

The production phone service deliberately throws `transportUnavailable` for prompt and restart actions.

## Listener default

The daemon remote service is disabled unless a valid local `remote.json` and identity configuration are supplied. This document intentionally does not provide a copy-paste public listener configuration while the feature remains experimental.

Do not:

- bind Guardian directly to a public interface
- forward its port from a router
- treat LAN or VPN membership as authentication
- share a pairing code or QR screenshot
- grant remote force-restart authority
- place prompts or secrets in push payloads

## Exit requirements

Before remote control becomes supported, the project needs live proof of pairing, revocation, key rotation, reconnect, sequence gaps, background/foreground behavior, LAN/VPN loss, offline commands, exact applied receipts, capability denial, rate limiting, and safe upgrade. A security review and simple provisioning/disable procedure are also required.

See [Phase 8 iPhone evidence](PHASE8_PHONE_UI_IMPLEMENTATION.md) for the current implementation boundary.
